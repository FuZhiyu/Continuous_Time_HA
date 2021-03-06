classdef MPCs < handle
	% This class contains methods that compute MPCs
	% over certain time periods. Baseline expected
	% consumption is found, and then this quantity--via
	% interpolation--is used to find expected consumption 
	% given an asset shock. Then MPCs are computed.
	%
	% Once the class is instantiated, the 'mpcs' results structure
	% is populated with NaN's. Calling solve() will compute
	% the MPCs.

	properties (Constant)
		% Update this array when the required parameters change.
		required_parameters = {'nb_KFE', 'na_KFE', 'nz', 'deathrate'};

		% Update this array when the required income variables
		% change.
		required_income_vars = {'ny', 'ytrans'};

		% Default option values.
		defaults = struct(...
					'delta', 0.01,...
					'interp_method', 'linear'...
					);
    end
    
	properties (SetAccess=protected)

		% An object with at least the following attributes:
		%
		%	deathrate
		%	- The Poisson rate of death.
		%
		%	nb_KFE, na_KFE, nz
		%	- Number of points on each grid.
		p;

		% An object with at least the following attributes:
		%
		%	ytrans
		%	- The square income transition matrix, rows should
		%	  sum to zero.
		%
		%	ny
		%	- The number of income states.
		income;

		% A Grid object defined on the KFE grids.
		grids;

		% Options used internally by this class.
		options;

		% Feynman-Kac divisor matrix
		FKmat; 

		% cumulative consumption
		cumcon; % current state
		cum_con_baseline; % baseline
		cum_con_shock = cell(1,6); % shocked

		% income transitions w/o diagonal
		ytrans_offdiag;

		% results structure
		mpcs = struct();

		solved = false;
	end

	methods
		function obj = MPCs(p, income, grids, varargin)
			% class constructor

			% Required Inputs
			% ---------------
			% p : An object that satisfies the requirements
			%	laid out by the class properties.
			%	
			% income : An object that satisfies the requirements
			%	laid out by the class properties.
			%
			% grids : A Grid object on the KFE grid.
			%
			% Optional Key-Value Inputs
			% -------------------------
			% delta : Step size used while iterating over the
			%	Feynman-Kac equation, default = 0.02.
			%
			% interp_method : Interpolation method passed to
			%	griddedInterpolant, default = 'linear'. See
			%	the MATLAB documentation for griddedInterpolant.
			%
			% Returns
			% -------
			% obj : an MPCs object	

			obj.options = parse_options(varargin{:});

			obj.p = p;
			obj.income = income;
			obj.grids = grids;

			obj.ytrans_offdiag = income.ytrans - diag(diag(income.ytrans));

			for ii = 1:6
				obj.mpcs(ii).mpcs = NaN;
				obj.mpcs(ii).quarterly = NaN(4,1);
                obj.mpcs(ii).annual = NaN;
			end
		end

		function solve(obj, KFE, pmf, A)
			% computes the MPCs using Feynman-Kac by calling
			% a sequence of class methods

			% Parameters
			% ----------
			% KFE : a structure containing the policy functions
			%	on the KFE grids
			%
			% pmf : the equilibrium probability mass function,
			%	of shape (nb_KFE, na_KFE, nz, ny)
			%
			% A : the transition matrix for the KFE
			%
			% Directly Modifies
			% -----------------
			% obj.mpcs : the computed MPC statistics
			%
			% Note
			% ----
			% This method also modifies other class properties
			% via other methods.

			if obj.solved
				error('Already solved, create another instance')
            end

			obj.FKmat = HACTLib.computation.feynman_kac_divisor(...
                obj.p, obj.income, obj.options.delta, A, true);
			obj.iterate_backward(KFE);

			for ishock = 1:6
				obj.cumulative_consumption_with_shock(ishock);
				obj.computeMPCs(pmf,ishock)
			end

			obj.solved = true;
		end
	end

	methods (Access=private)

		function iterate_backward(obj, KFE)
			% iterates backward four quarters on the Feynman-Kac equation
			% to compute cum_con_baseline
			%
			% each quarter is split into 1/delta subperiods, which
			% are then iterated over

			% Parameters
			% ----------
			% KFE : a structure containing the policy functions and the
			%	value function, on the KFE grid
			%
			% Directly Modifies
			% -----------------
			% obj.cum_con_baseline : cumulative consumption at a given
			%	quarter for the baseline case, where the second dimension
			%	is the quarter; of shape (nb_KFE*na_KFE*nz*ny, num_quarters)
			%
			% Note
			% ----
			% This method also modifies other class properties
			% via other methods.

			import HACTLib.computation.feynman_kac

			dim = obj.p.nb_KFE*obj.p.na_KFE*obj.p.nz*obj.income.ny;
			obj.cumcon = zeros(dim,4);
			for it = 4:-obj.options.delta:obj.options.delta
				if mod(it*4,1) == 0
					fprintf('\tUpdating baseline cumulative consumption, quarter=%0.2f\n',it)
				end

				for period = ceil(it):4
					% when 'it' falls to 'period', start updating
					% that 'period'
					obj.cumcon(:,period) = feynman_kac(obj.p, obj.grids,...
						obj.income, obj.cumcon(:,period), obj.FKmat, KFE.c, obj.options.delta);
				end
			end

			obj.cum_con_baseline = zeros(dim,4);
			obj.cum_con_baseline(:,1) = obj.cumcon(:,1);
			for period = 2:4
				obj.cum_con_baseline(:,period) = obj.cumcon(:,period)...
					- obj.cumcon(:,period-1);
			end

		    obj.cum_con_baseline = reshape(obj.cum_con_baseline,[],4);
		end

		function cumulative_consumption_with_shock(obj, ishock)
			% use baseline cumulative consumption to approximate
			% cumulative consumption for households presented with
			% an income shock in the first period

			% Parameters
			% ----------
			% ishock : the index of the shock, in reference to the
			%	shocks vector contained in the Params object used to
			%	instantiate this class
			%
			% Modifies
			% --------
			% obj.cum_con_shock : a cell array, indexed by shock, containing
			%	cumulative consumption over states for a given period; each
			%	cell contains an array of shape (nb_KFE*na_KFE*nz*ny, num_periods)

			shock = obj.p.mpc_shocks(ishock);
			bgrid_mpc_vec = obj.grids.b.vec + shock;

			if shock < 0
	            below_bgrid = bgrid_mpc_vec < obj.grids.b.vec(1);
	            bgrid_mpc_vec(below_bgrid) = obj.grids.b.vec(1);
	        end

	        % grids for interpolation
	        interp_grids = {obj.grids.b.vec, obj.grids.a.vec,...
	        	obj.grids.z.vec, obj.income.y.vec};
	       	value_grids = {bgrid_mpc_vec, obj.grids.a.vec,...
	       		obj.grids.z.vec, obj.income.y.vec};

        	if (obj.income.ny > 1) && (obj.p.nz > 1)
                inds = 1:4;
            elseif (obj.income.ny==1) && (obj.p.nz > 1)
                inds = 1:3;
            elseif obj.income.ny > 1
                inds = [1, 2, 4];
            else
                inds = [1, 2];
            end

            interp_grids = interp_grids(inds);
            value_grids = value_grids(inds);

			reshape_vec = [obj.p.nb_KFE obj.p.na_KFE obj.p.nz obj.income.ny];
			for period = 1:4
				% cumulative consumption in 'period'
	            con_period = reshape(obj.cum_con_baseline(:,period),reshape_vec);
	            mpcinterp = griddedInterpolant(interp_grids,squeeze(con_period),'linear');

	            obj.cum_con_shock{ishock}(:,period) = reshape(mpcinterp(value_grids), [], 1);

	            if (shock < 0) && (sum(below_bgrid)>0) && (period==1)
	                temp = reshape(obj.cum_con_shock{ishock}(:,period),reshape_vec);
	                temp(below_bgrid,:,:,:) = con_period(1,:,:,:) + shock...
	                	+ obj.grids.b.vec(below_bgrid) - obj.grids.b.vec(1);
	                obj.cum_con_shock{ishock}(:,period) = temp(:);                      
	            end
	        end
		end

		function computeMPCs(obj, pmf, ishock)
			% compute MPCs using the cumulative consumption arrays
			% found previously

			% Parameters
			% ----------
			% pmf : the equilibrium probability mass function of the
			%	baseline, of shape (nb_KFE, na_KFE, nz, ny)
			%
			% ishock : the shock index, in reference to the shock vector
			%	in the Params object used to instantiate this class
			%
			% Modifies
			% --------
			% obj.mpcs : the final MPC statistics computed from this class,
			%	a structure array of size nshocks
			
			shock = obj.p.mpc_shocks(ishock);

			% MPCs out of a shock at beginning of quarter 0
			mpcs = (obj.cum_con_shock{ishock} - obj.cum_con_baseline) / shock;
			if ishock == 5
				obj.mpcs(5).mpcs = mpcs;
			end

			obj.mpcs(ishock).quarterly = mpcs' * pmf(:);
			obj.mpcs(ishock).annual = sum(mpcs,2)' * pmf(:);
		end

		function check_income(obj, income)
			HACTLib.Checks.has_attributes('MPCs',...
				income, obj.required_income_vars);
			assert(ismatrix(income.ytrans), "Income transition matrix must be a matrix");
			assert(size(income.ytrans, 1) == income.ny,...
				"Income transition matrix has different size than (ny, ny)");
			assert(numel(income.ydist(:)) == income.ny,...
				"Income distribution has does not have ny elements");
			assert(income.ny > 0, "Must have ny >= 1");
		end

		function check_parameters(obj, p)
			HACTLib.Checks.has_attributes('MPCs',...
				p, obj.required_parameters);
		end
	end
end

function options = parse_options(varargin)
	import HACTLib.computation.MPCs
	import HACTLib.aux.parse_keyvalue_pairs

	defaults = MPCs.defaults;
	options = parse_keyvalue_pairs(defaults, varargin{:});

	mustBePositive(options.delta);
	if ~ismember(options.interp_method, {'linear', 'nearest',...
		'next', 'previous', 'pchip', 'cubic', 'spline', 'makima'})
		error("HACTLib:MPCs:InvalidArgument",...
			strcat("Invalid interpolation method entered.",...
				"Check griddedInterpolant documentation."))
	end
end