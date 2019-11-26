classdef (Abstract) HJBBase < handle

	properties (Abstract, Constant)
		required_parameters;
		required_income_vars;
	end

	properties (SetAccess=protected)
		%	An object with the following required attributes:
		%
		%		nb, na, nz
		%
		%		rho > 0
		%		- The time discount factor.
		%
		%		rhos
		%		- A vector indicating all possible values for rho.
		%		  If there is no rho heterogeneity, set rhos = [].
		%
		%		deathrate > 0
		%
		%		SDU
		%		- A boolean indicator, true if using stochastic
		%		  differential utility and false otherwise.
		p;

		%	An object with the following required attributes:
		%
		%		ny
		%	
		%		ytrans
		%		- The income transition matrix, should have row sums
		%		  of zero and shape (ny, ny).
		%
		%	and if using stochastic differential utility, the following
		%	is a required method:
		%
		%		income_transitions_SDU(p, V)
		%		- Must accept two arguments, p and V, and must return
		%		  an array of shape (nb*na*nz, ny, ny) to be used as
		%		  the adjusted income transition rates.
		%
		%	and--again for stochastic differential utility, the following
		%	method is required, or 'sparse_income_transitions' can be
		%	an attribute of the 'income' variable, in which case it must
		%	be a sparse array of size (nb*na*nz*ny, nb*na*nz*ny) indicating
		%	the adjusted income transition rates:
		%
		%		income_transition_matrix_SDU(p, ez_adj, 'HJB')
		%		- Must accept the three arguments above. The variable
		%		  'ez_adj' is the array generated by the
		%		  income_transitions_SDU() method.
		income;

		% Total number of states.
		n_states;

		% Number of states per income level.
		states_per_income;

		% Number of states along each dim, a vector.
		shape;

		% Sparse matrix of discount factors.
		rho_mat;
        
        % An HJBOptions object.
        options;

        % Current iteration, needed for the HIS.
        current_iteration = 0;
	end

	methods
		function obj = HJBBase(p, income, options)
			% See the properties block above or view this class'
			% documentation to see the requirements of the
			% input parameters.

			import HACT_Tools.options.HJBOptions

			% ---------------------------------------------------------
			% Validate Input Arguments and Set Options
			% ---------------------------------------------------------
			obj.check_parameters(p);
			obj.p = p;

			obj.check_income(income);
			obj.income = income;

			if exist('options', 'var')
				assert(isa(options, 'HJBOptions'),...
					"options argument must be a HJBOptions object");
				obj.options = options;
			else
				obj.options = HJBOptions();
			end

			obj.n_states = p.nb * p.na * p.nz * income.ny;
			obj.states_per_income = p.nb * p.na * p.nz;
			obj.shape = [p.nb p.na p.nz income.ny];

			% ---------------------------------------------------------
			% Discount Factor Matrix
			% ---------------------------------------------------------
			obj.create_rho_matrix();
		end
	end

	methods (Access=protected)
		function obj = create_rho_matrix(obj)
			if obj.options.implicit
				% discount factor values
		        if numel(obj.p.rhos) > 1
		            rhocol = repmat(kron(obj.p.rhos(:), ones(obj.p.nb*obj.p.na, 1)), obj.income.ny, 1);
		            obj.rho_mat = spdiags(rhocol, 0, obj.n_states, obj.n_states);
		        else
		            obj.rho_mat = obj.p.rho * speye(obj.n_states);
		        end
		    else
		    	if numel(obj.p.rhos) > 1
			        rhocol = kron(obj.p.rhos(:), ones(obj.p.nb*obj.p.na,1));
			        obj.rho_mat = spdiags(rhocol, obj.states_per_income, obj.states_per_income);
			    else
			        obj.rho_mat = obj.p.rho * speye(obj.states_per_income);
			    end
	    	end
		end

		function check_inputs(obj, A, u, V)
			import HACT_Tools.Checks;

			Checks.is_square_sparse_matrix(A, obj.n_states);
			Checks.has_shape(u, obj.shape);
			Checks.has_shape(V, obj.shape);
		end

		function Bk = construct_Bk(obj, k, A, inctrans, varargin)
		    % For the k-th income state, constructs the matrix
		    % Bk = (rho + deathrate - A)*delta + I, which serves
		    % as the divisor in the implicit-explicit update scheme.

		    i1 = 1 + (k-1) * obj.states_per_income;
		    i2 = k * obj.states_per_income;

		    Ak = A(i1:i2, i1:i2);
		    Bk = obj.options.delta * obj.rho_mat...
		    	+ (1 + obj.options.delta * obj.p.deathrate) * speye(obj.states_per_income)...
		        - obj.options.delta * (Ak + inctrans);
		end

		function check_parameters(obj, p)
			HACT_Tools.Checks.has_attributes(....
				p, obj.required_parameters);
		end

		function check_income(obj, income)
			HACT_Tools.Checks.has_attributes(...
				income, obj.required_income_vars);
			HACT_Tools.Checks.is_square_matrix(income.ytrans);
		end
	end

	methods (Abstract)
		V_update = solve(obj, A, u, V, varargin);
	end

	methods (Abstract, Access=protected)
		check_if_SDU(obj);
		Vn1 = solve_implicit(obj, A, u, V, varargin);
	end

end