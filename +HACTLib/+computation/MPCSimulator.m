classdef MPCSimulator < handle
	% Simulator for MPCs out of an immediate shock or out
	% of news.
	%
	% Once the solve() method is called, results are
	% stored in the 'sim_mpcs' property. If simulations are not
	% performed, results will be NaN.
	%
	% MPCs out of news are simulated as ordinary MPCs, except
	% that the policy function interpolants are loaded
	% from .mat files saved by the MPCsNews class.
	%
	% Simulated variables are indexed by household in the row
	% dimension and shock size in the column dimension, with the
	% first column corresponding to a shock of 0, and the
	% remaining columns corresponding the shock sizes indexed
	% by 'shocks.'

	properties (SetAccess = protected)
		p;
		income;
		grids;

		% state variables
		asim;
		csim;
		ysim;
        yrep;
		bsim;
		yinds;
		zinds;
		zindsrep;
        
        cum_ytrans;

		% initial assets
		b0;
        
        % indicator equal to one if a negative MPC shock
        % pushed the household below the bottom of the
        % asset grid
        below_bgrid;

        % grids used to interpolate policy functions
		interp_grids;

		interp_grid_indices;

		% policy function interpolants
		dinterp;
		sinterp;
		cinterp;

		% cumulative consumption functions
		cum_con;
		baseline_cum_con; % final baseline cumcon
		shock_cum_con; % final shocked cumcon

		mpc_delta; % time delta
		shocks; % selected shocks from the parameters, e.g. [4,5]
		nshocks; % numel(shocks)
		nperiods; % number of quarters to iterate over
		shockperiod;
        deathrateSubperiod;

		sim_mpcs = struct();

		simulationComplete = false;

		savedTimes;
	end

	methods
		%% ---------------------------------------------------
	    % CLASS GENERATOR
	    % ----------------------------------------------------
		function obj = MPCSimulator(p, income, grids, policies,...
			shocks, shockperiod, savedTimes)

			obj.p = p;
			obj.income = income;
			obj.grids = grids;
			obj.deathrateSubperiod = 1 - (1-obj.p.deathrate) ^ (1/p.T_mpcsim);

			obj.mpc_delta = 1 / p.T_mpcsim;
			obj.shocks = shocks;
			obj.nshocks = numel(shocks);
			obj.shockperiod = shockperiod;

			if shockperiod == 1
				obj.nperiods = 1;
			else
				obj.nperiods = 4;
			end

			% initialize mpc results to NaN
			for ishock = 1:6
				obj.sim_mpcs(ishock).avg_quarterly = NaN(obj.nperiods, 1);
				obj.sim_mpcs(ishock).avg_annual = NaN;
			end

			if nargin == 7
				obj.savedTimes = savedTimes;
			end

			interp_grids = {obj.grids.b.vec, obj.grids.a.vec,...
				obj.grids.z.vec, (1:obj.income.ny)'};
			if (income.ny > 1) && (p.nz > 1)
                obj.interp_grid_indices = 1:4;
            elseif p.nz > 1
            	obj.interp_grid_indices = 1:3;
            elseif income.ny > 1
                obj.interp_grid_indices = [1, 2, 4];
            else
                obj.interp_grid_indices = 1:2;
            end

            obj.interp_grids = interp_grids(obj.interp_grid_indices);
            obj.dinterp{1} = griddedInterpolant(obj.interp_grids, squeeze(policies.d), 'linear');
			obj.cinterp{1} = griddedInterpolant(obj.interp_grids, squeeze(policies.c), 'linear');
			obj.sinterp{1} = griddedInterpolant(obj.interp_grids, squeeze(policies.s), 'linear');
		end

		%% ---------------------------------------------------
	    % RUN SIMULATION
	    % ----------------------------------------------------
	    function solve(obj,pmf)
	    	% solve() calls functions to draw from the stationary
	    	% distribution, run simulations, and compute MPCs

	    	if obj.p.nz > 1
	    		warning('MPCSimulator not yet configured for nz > 1')
	    		return
	    	end

	    	rng(15996);

	    	if obj.simulationComplete
	    		error('Simulations already run, create a new instance instead')
	    	elseif obj.shockperiod > 0
	    		fprintf('Simulating MPCs out of news of a shock in %i quarter(s)...\n',obj.shockperiod)
            end
            
            % discretize transition matrix
            disc_ytrans = eye(obj.income.ny) + obj.mpc_delta * obj.income.ytrans;
            obj.cum_ytrans = cumsum(disc_ytrans, 2);

	    	obj.draw_from_stationary_dist(pmf);
	    	obj.run_simulations();

	    	for period = 1:obj.nperiods
	    		obj.compute_mpcs(period);
            end

	    	obj.simulationComplete = true;
	    end

		%% ---------------------------------------------------
	    % INITIAL DRAW FROM STATIONARY DISTRIBUTION
	    % ----------------------------------------------------
		function index = draw_from_stationary_dist(obj, pmf)
			% this function draws from the stationary distribution
			% 'pmf'
			%
			% output is a vector of positive integers indicating
			% the household's initial state within 'pmf'

			fprintf('\tDrawing from stationary distribution\n')
			cumdist = cumsum(pmf(:));
			draws = rand(obj.p.n_mpcsim,1,'single');

			index = zeros(obj.p.n_mpcsim,1);
			chunksize = 5e2;
			finished = false;
			i1 = 1;
			i2 = min(chunksize,obj.p.n_mpcsim);
			while ~finished
		        [~,index(i1:i2)] = max(draws(i1:i2)<=cumdist',[],2);
		        
		        i1 = i2 + 1;
		        i2 = min(i1+chunksize,obj.p.n_mpcsim);
		        
		        if i1 > obj.p.n_mpcsim
		            finished = true;
		        end
			end

			% initial income
			ygrid_flat = obj.income.y.matrixKFE(:);
			obj.ysim = ygrid_flat(index);
            obj.yrep = repmat(obj.ysim,obj.nshocks+1, 1);
			yind_trans = kron((1:obj.income.ny)', ones(obj.p.nb_KFE*obj.p.na_KFE*obj.p.nz, 1));
			obj.yinds = yind_trans(index);

			% initial assets
			bgrid_flat = obj.grids.b.matrix(:);
			obj.bsim = repmat(bgrid_flat(index), 1, obj.nshocks+1);
			obj.b0 = obj.bsim;
            
            if obj.shockperiod == 0
                for i = 2:obj.nshocks+1
                    ishock = obj.shocks(i-1);
                    obj.bsim(:,i) = obj.bsim(:,i) + obj.p.mpc_shocks(ishock);
                end
            end

            % initial z-heterogeneity
        	zgrid_flat = obj.grids.z.matrix(:);
        	obj.zinds = zgrid_flat(index);
        	obj.zindsrep = repmat(obj.zinds, obj.nshocks+1, 1);

            % initial illiquid assets
			agrid_flat = obj.grids.a.matrix(:);
			obj.asim = repmat(agrid_flat(index), 1, obj.nshocks+1);

		    % record households pushed below grid, and bring them
		    % up to bottom of grid
		    obj.below_bgrid = obj.bsim < obj.grids.b.vec(1);
		    obj.bsim(obj.below_bgrid) = obj.grids.b.vec(1);
		end

		%% ---------------------------------------------------
	    % PERFORM MAIN SIMULATIONS
	    % ----------------------------------------------------
	    function run_simulations(obj)
	    	obj.baseline_cum_con = zeros(obj.p.n_mpcsim,obj.nperiods);
	    	obj.shock_cum_con = cell(1,6);

	    	for period = 1:obj.nperiods
	    		fprintf('\tSimulating quarter %i\n',period)
                obj.cum_con = zeros(obj.p.n_mpcsim, obj.nshocks+1);
		    	for subperiod = 1:obj.p.T_mpcsim
		    		% time elapsed starting from zero
		    		actualTime = (period-1) + (subperiod-1) / obj.p.T_mpcsim;
                    
                    % redraw random numbers for income in chunks of 100 periods
                    tmod100 = mod(subperiod,100);
                    if tmod100 == 1
                        inc_rand_draws = rand(obj.p.n_mpcsim,100,2,'single');
                    elseif tmod100 == 0
                        tmod100 = 100;
                    end
            
            		current_csim = obj.csim;
            		obj.update_interpolants(actualTime);
		    		obj.simulate_consumption_one_period();
		    		obj.simulate_assets_one_period();
		    		obj.simulate_income_and_death_one_period(inc_rand_draws(:,tmod100,:));
                end
                
                % finished with this period
                obj.baseline_cum_con(:,period) = obj.cum_con(:,1);

                for i = 1:obj.nshocks
                    ishock = obj.shocks(i);
                    obj.shock_cum_con{ishock}(:,period) = obj.cum_con(:,i+1);

                    if period == 1
                    	% adjustment for states that were pushed below bottom
                    	% of asset grid
	                	obj.shock_cum_con{ishock}(obj.below_bgrid) = ...
	                		obj.shock_cum_con{ishock}(obj.below_bgrid) ...
	                		+ obj.b0(obj.below_bgrid) + obj.p.mpc_shocks(ishock) ...
	                		- obj.grids.b.vec(1);
                	end
                end
			end
	    end

	    function simulate_consumption_one_period(obj)
	    	c = zeros(obj.p.n_mpcsim, obj.nshocks+1);
	    	for k = 1:obj.nshocks+1
	    		if obj.shockperiod == 0
	    			interp_num = 1;
	    		else
	    			interp_num = k;
	    		end

	    		vals = {obj.bsim(:,k), obj.asim(:,k),...
	    			obj.zinds(:), obj.yinds(:)};
	    		vals = vals(obj.interp_grid_indices);
	    		c(:,k) = obj.cinterp{interp_num}(vals{:});
	    	end

	    	obj.cum_con = obj.cum_con + c * obj.mpc_delta;
	    end

	    function simulate_assets_one_period(obj,~)
	    	% this function simulates assets over the next time
	    	% delta

	    	% interpolate to find decisions
	    	s = zeros(obj.p.n_mpcsim, obj.nshocks+1);
	    	d = zeros(obj.p.n_mpcsim, obj.nshocks+1);
	    	for k = 1:obj.nshocks+1
	    		if obj.shockperiod == 0
	    			interp_num = 1;
	    		else
	    			interp_num = k;
	    		end

	    		vals = {obj.bsim(:,k), obj.asim(:,k),...
	    			obj.zinds(:), obj.yinds(:)};
	    		vals = vals(obj.interp_grid_indices);
	    		s(:,k) = obj.sinterp{interp_num}(vals{:});
	    		d(:,k) = obj.dinterp{interp_num}(vals{:});
	    	end

	    	% update liquid assets
	    	obj.bsim = obj.bsim + obj.mpc_delta ...
				* (s - d - aux.AdjustmentCost.cost(d, obj.asim, obj.p));
			obj.bsim = max(obj.bsim, obj.grids.b.vec(1));
			obj.bsim = min(obj.bsim, obj.grids.b.vec(end));

			% update illiquid assets
	    	obj.asim = obj.asim + obj.mpc_delta ...
	            * (d + (obj.p.r_a+obj.p.deathrate*obj.p.perfectannuities) * obj.asim ...
				+ obj.p.directdeposit*obj.ysim);
	        obj.asim = max(obj.asim, obj.grids.a.vec(1));
	        obj.asim = min(obj.asim, obj.grids.a.vec(end));
	    end

		%% ---------------------------------------------------
	    % SIMULATE INCOME AND DEATH FOR ONE PERIOD
	    % ----------------------------------------------------
	    function simulate_income_and_death_one_period(obj, draws)
			chunksize = 5e2;
			finished = false;
			i1 = 1;
			i2 = min(chunksize, obj.p.n_mpcsim);
			while ~finished
		        [~,obj.yinds(i1:i2)] = max(draws(i1:i2,1)...
		        	<= obj.cum_ytrans(obj.yinds(i1:i2),:), [], 2);

		        if obj.p.Bequests == 0
		        	lived = draws(i1:i2,2) > obj.deathrateSubperiod;
		        	obj.bsim(i1:i2,:) = lived .* obj.bsim(i1:i2,:);
		        	obj.asim(i1:i2,:) = lived .* obj.asim(i1:i2,:);
		        end
		        
		        i1 = i2 + 1;
		        i2 = min(i1+chunksize, obj.p.n_mpcsim);
		        
		        if i1 > obj.p.n_mpcsim
		            finished = true;
		        end
			end

	        obj.ysim = obj.income.y.vec(obj.yinds);
            obj.yrep = repmat(obj.ysim, obj.nshocks+1, 1);
	    end

    	function compute_mpcs(obj, period)
		    for is = 1:obj.nshocks
		    	ishock = obj.shocks(is); % index of shock in parameters
		    	shock = obj.p.mpc_shocks(ishock);

		    	con_diff = obj.shock_cum_con{ishock} - obj.baseline_cum_con;
            
            	if (shock > 0) || ismember(obj.shockperiod, [0,1])
	            	obj.sim_mpcs(ishock).avg_quarterly(period) = mean(con_diff(:,period)) / shock;
	            end

	            if ((shock > 0) || (obj.shockperiod == 4)) && (obj.nperiods >= 4)
                    obj.sim_mpcs(ishock).avg_annual = mean(sum(con_diff,2) / shock);
                end
		    end
        end
        
        function update_interpolants(obj, actualTime)
        	if obj.shockperiod <= actualTime
            	return
            end

            timeUntilShock = obj.shockperiod - actualTime;
            [~, closest1] = min(abs(obj.savedTimes-timeUntilShock));
            if obj.savedTimes(closest1) < timeUntilShock
            	closest1 = closest1 - 1;
            end
            closest2 = closest1 + 1;

            % index = find(obj.savedTimes == timeUntilShock);

            for k = 1:obj.nshocks
            	ishock = obj.shocks(k);
            	name1 = sprintf('policy%ishock%i.mat', closest1, ishock);
            	lpath1 = fullfile(obj.p.temp_dir, name1);
            	policies1 = load(lpath1);

            	if closest2 <= numel(obj.savedTimes)
            		name2 = sprintf('policy%ishock%i.mat', closest2, ishock);
            		lpath2 = fullfile(obj.p.temp_dir, name2);
            		policies2 = load(lpath2);

	            	weight1 = (obj.savedTimes(closest1) - timeUntilShock)...
							/ (obj.savedTimes(closest2) - obj.savedTimes(closest1));
				else
					weight1 = 1;
				end
				weight2 = 1 - weight1;

				weight1 = max(min(weight1, 1), 0);
				weight2 = max(min(weight2, 1), 0);

				if closest2 <= numel(obj.savedTimes)
					d = weight1 * policies1.d + weight2 * policies2.d;
					c = weight1 * policies1.c + weight2 * policies2.c;
					s = weight1 * policies1.s + weight2 * policies2.s;
				else
					d = policies1.d;
					c = policies1.c;
					s = policies1.s;
				end

	            obj.dinterp{k+1} = griddedInterpolant(obj.interp_grids,...
	            	squeeze(d), 'linear');
				obj.cinterp{k+1} = griddedInterpolant(obj.interp_grids,...
					squeeze(c), 'linear');
				obj.sinterp{k+1} = griddedInterpolant(obj.interp_grids,...
					squeeze(s), 'linear');
			end
        end
	end
end