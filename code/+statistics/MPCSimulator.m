classdef MPCSimulator < handle
	% This class draws from the stationary distribution computed
	% from the KFE and simulates a chosen number of quarters
	% to compute MPCs and various statistics.

	% Once the solve() method is called, results are
	% stored in the 'sim_mpcs' property. If simulations are not
	% performed, results will be NaN

	% Note that state variables are updated at each time delta,
	% I do not store arrays of intermediate values.

	properties (SetAccess = protected)
		% state variables
		csim;
		ysim;
        yrep;
		bsim;
		yinds;
        
        cum_ytrans;

		% baseline assets
		b0;
        
        below_bgrid;

		interp_grids;

		% cumulative consumption functions
		cum_con;
		baseline_cum_con; % final baseline cumcon
		shock_cum_con; % final shocked cumcon

		mpc_delta; % time delta
		shocks; % selected shocks from the parameters, e.g. [4,5]
		nshocks;
		nperiods; % number of quarters to use
		shockperiod;
		dim2Identity;
		dim2;

		sim_mpcs = struct();

		simulationComplete = false;
	end

	methods
		%% ---------------------------------------------------
	    % CLASS GENERATOR
	    % ----------------------------------------------------
		function obj = MPCSimulator(p,income,grids,policies,shocks,shockperiod,dim2Identity)
			obj.mpc_delta = 1 / p.T_mpcsim;
			obj.shocks = shocks;
			obj.nshocks = numel(shocks);
			obj.shockperiod = shockperiod;

			if shockperiod == 1
				obj.nperiods = 1;
			else
				obj.nperiods = 4;
			end

			obj.dim2Identity = dim2Identity;
			if strcmp(dim2Identity,'a')
				obj.dim2 = p.na_KFE;
			elseif strcmp(dim2Identity,'c')
				obj.dim2 = p.nc_KFE;
			end

			% initialize mpc results to NaN
			for ishock = 1:6
				obj.sim_mpcs(ishock).avg_quarterly = NaN(obj.nperiods,1);
				obj.sim_mpcs(ishock).avg_annual = NaN;
			end
		end

		%% ---------------------------------------------------
	    % RUN SIMULATION
	    % ----------------------------------------------------
	    function solve(obj,p,income,grids,pmf)
	    	rng(15996);

	    	if obj.simulationComplete
	    		error('Simulations already run, create a new instance instead')
	    	elseif obj.shockperiod > 0
	    		fprintf('Simulating MPCs out of news of a shock in %i quarter(s)...\n',obj.shockperiod)
            end
            
            % discretize transition matrix
            disc_ytrans = eye(income.ny) + obj.mpc_delta * income.ytrans;
        %     disc_ytrans = inv(eye(income.ny)-mpc_delta*income.ytrans);
            obj.cum_ytrans = cumsum(disc_ytrans,2);

	    	obj.draw_from_stationary_dist(p,income,grids,pmf);
	    	obj.run_simulations(p,income,grids);

	    	for period = 1:obj.nperiods
	    		obj.compute_mpcs(p,period);
            end

	    	obj.simulationComplete = true;
	    end

		%% ---------------------------------------------------
	    % INITIAL DRAW FROM STATIONARY DISTRIBUTION
	    % ----------------------------------------------------
		function index = draw_from_stationary_dist(obj,p,income,grids,pmf)
			fprintf('\tDrawing from stationary distribution\n')
			cumdist = cumsum(pmf(:));
			draws = rand(p.n_mpcsim,1,'single');

			index = zeros(p.n_mpcsim,1);
			chunksize = 5e2;
			finished = false;
			i1 = 1;
			i2 = min(chunksize,p.n_mpcsim);
			while ~finished
		        [~,index(i1:i2)] = max(draws(i1:i2)<=cumdist',[],2);
		        
		        i1 = i2 + 1;
		        i2 = min(i1+chunksize,p.n_mpcsim);
		        
		        if i1 > p.n_mpcsim
		            finished = true;
		        end
			end

			% initial income
			ygrid_flat = income.y.matrixKFE(:);
			obj.ysim = ygrid_flat(index);
            obj.yrep = repmat(obj.ysim,obj.nshocks+1,1);
			yind_trans = kron((1:income.ny)',ones(p.nb_KFE*obj.dim2,1));
			obj.yinds = yind_trans(index);

			% initial assets
			bgrid_flat = grids.b.matrix(:);
			obj.bsim = repmat(bgrid_flat(index),1,obj.nshocks+1);
			obj.b0 = obj.bsim;
		    for i = 2:obj.nshocks+1
		        ishock = obj.shocks(i-1);
		        obj.bsim(:,i) = obj.bsim(:,i) + p.mpc_shocks(ishock);
		    end

		    obj.below_bgrid = obj.bsim < grids.b.vec(1);
		    obj.bsim(obj.below_bgrid) = grids.b.vec(1);
		end

		%% ---------------------------------------------------
	    % PERFORM MAIN SIMULATIONS
	    % ----------------------------------------------------
	    function run_simulations(obj,p,income,grids)
	    	obj.baseline_cum_con = zeros(p.n_mpcsim,obj.nperiods);
	    	obj.shock_cum_con = cell(1,6);

	    	for period = 1:obj.nperiods
	    		fprintf('\tSimulating quarter %i\n',period)
                obj.cum_con = zeros(p.n_mpcsim,obj.nshocks+1);
		    	for subperiod = 1:p.T_mpcsim
		    		actualTime = (period-1) + (subperiod-1) / p.T_mpcsim;
                    
                    % redraw random numbers for income in chunks of 100 periods
                    tmod100 = mod(subperiod,100);
                    if tmod100 == 1
                        inc_rand_draws = rand(p.n_mpcsim,100,'single');
                    elseif tmod100 == 0
                        tmod100 = 100;
                    end
            
            		current_csim = obj.csim;
            		obj.update_interpolants(p,actualTime);
		    		obj.simulate_consumption_one_period(p,income,grids);
		    		obj.simulate_assets_one_period(p,grids,current_csim);
		    		obj.simulate_income_one_period(p,income,inc_rand_draws(:,tmod100));
                end
                
                % finished with this period
                obj.baseline_cum_con(:,period) = obj.cum_con(:,1);

                for i = 1:obj.nshocks
                    ishock = obj.shocks(i);
                    obj.shock_cum_con{ishock}(:,period) = obj.cum_con(:,i+1);

                    if period == 1
                    	% adjust for states that were pushed below bottom
                    	% of asset grid
	                	obj.shock_cum_con{ishock}(obj.below_bgrid) = ...
	                		obj.shock_cum_con{ishock}(obj.below_bgrid) ...
	                		+ obj.b0(obj.below_bgrid) + p.mpc_shocks(ishock) ...
	                		- grids.b.vec(1);
                	end
                end
			end
	    end

		%% ---------------------------------------------------
	    % SIMULATE INCOME PROCESS ONE PERIOD
	    % ----------------------------------------------------
	    function simulate_income_one_period(obj,p,income,draws)
	    	% redraw random numbers in chunks of 100 periods

			chunksize = 5e2;
			finished = false;
			i1 = 1;
			i2 = min(chunksize,p.n_mpcsim);
			while ~finished
		        [~,obj.yinds(i1:i2)] = max(draws(i1:i2)...
		        	<=obj.cum_ytrans(obj.yinds(i1:i2),:),[],2);
		        
		        i1 = i2 + 1;
		        i2 = min(i1+chunksize,p.n_mpcsim);
		        
		        if i1 > p.n_mpcsim
		            finished = true;
		        end
			end

	        obj.ysim = income.y.vec(obj.yinds);
            obj.yrep = repmat(obj.ysim,obj.nshocks+1,1);
	    end

    	function compute_mpcs(obj,p,period)
		    for is = 1:obj.nshocks
		    	ishock = obj.shocks(is); % index of shock in parameters
		    	shock = p.mpc_shocks(ishock);

		    	con_diff = obj.shock_cum_con{ishock} - obj.baseline_cum_con;
            
            	if (shock > 0) || ismember(obj.shockperiod,[0,1])
	            	obj.sim_mpcs(ishock).avg_quarterly(period) = mean(con_diff(:,period)) / shock;
	            end

	            if (shock > 0) || (obj.shockperiod == 4)
                    obj.sim_mpcs(ishock).avg_annual = mean(sum(con_diff,2) / shock);
                end
		    end
        end
        
        function update_interpolants(obj,p,actualTime)
            % not coded yet
        end
	end
end