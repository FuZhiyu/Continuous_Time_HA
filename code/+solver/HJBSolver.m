classdef HJBSolver
	% A solver for the Hamilton-Jacobi-Bellman equation.
	% Implicit and implicit-explicit solution methods are
	% provided.
	%
	% The recommended use of this class is to first create
	% a Params object and an Income object, and pass these
	% to the HJBSolver constructor. Alternatively, one can
	% use other objects that satisfy the requirements laid
	% out in the properties block.

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

		% Sparse matrix of discount factors.
		rho_mat;
        
        % An HJBOptions object.
        options;

        % Current iteration, needed for the HIS.
        current_iteration = 0;
	end

	methods
		function obj = HJBSolver(p, income, options)
			% See the properties block above or view this class'
			% documentation to see the requirements of the
			% input parameters.

			% ---------------------------------------------------------
			% Validate Input Arguments and Set Options
			% ---------------------------------------------------------
			check_parameters(p);
			obj.p = p;

			check_income(income);
			obj.income = income;

			if exist('options', 'var')
				assert(isa(options, 'solver.HJBOptions'),...
					"options argument must be a HJBOptions object");
				obj.options = options;
			else
				obj.options = solver.HJBOptions();
			end

			obj.n_states = p.nb * p.na * p.nz * income.ny;
			obj.states_per_income = p.nb * p.na * p.nz;

			% ---------------------------------------------------------
			% Discount Factor Matrix
			% ---------------------------------------------------------
			obj.create_rho_matrix();
		end

		function create_rho_matrix(obj)
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
			        rhocol = kron(obj.p.rhos(:), ones(p.nb*p.na,1));
			        obj.rho_mat = spdiags(rhocol, obj.states_per_income, obj.states_per_income);
			    else
			        obj.rho_mat = obj.p.rho * speye(obj.states_per_income);
			    end
	    	end
		end

		function Vn1 = solve_implicit(obj, A, u, V, risk_adj)
			assert(obj.p.deathrate == 0, "Fully implicit assumes no death.")

	        % add income transitions
	        if obj.p.SDU
	        	B = A + obj.income.income_transition_matrix_SDU(obj.p, V);
	        else
	        	B = A + kron(obj.income.ytrans, speye(obj.states_per_income));
	        end

	        if isempty(risk_adj)
	            RHS = obj.options.delta * u(:) + Vn(:);
	        else
	            RHS = obj.options.delta * (u(:) + risk_adj(:)) + Vn(:);
	        end
	        
	        B = (rho_mat - B) * obj.options.delta + speye(obj.n_states);
	        Vn1 = B \ RHS;
	        Vn1 = reshape(Vn1, obj.p.nb, obj.p.na, obj.p.nz, obj.income.ny);
		end

		function Vn1 = solve_implicit_explicit(obj, A, u, V, risk_adj)
			obj.current_iteration = obj.current_iteration + 1;

			u_k = reshape(u, [], obj.income.ny);
            risk_adj_k = reshape(risk_adj, [], obj.income.ny);

	        Vn1_k = zeros(obj.states_per_income, obj.income.ny);
	        Vn_k = reshape(V, [], obj.income.ny);
	        Bik_all = cell(obj.income.ny, 1);

	        if obj.p.SDU
	        	ez_adj = obj.income.income_transitions_SDU(obj.p, V);
	        else
	        	ez_adj = [];
	        end

	        % loop over income states
	        for kk = 1:obj.income.ny
	            Bk = obj.construct_Bk(kk, A, ez_adj);
	            
	            Bik_all{kk} = inverse(Bk);
	            indx_k = ~ismember(1:obj.income.ny,kk);

	            if obj.p.SDU == 1
	                Vkp_stacked = sum(squeeze(ez_adj(:, kk, indx_k)) .* Vn_k(:, indx_k), 2);
	            else
	                Vkp_stacked = sum(repmat(obj.income.ytrans(kk,indx_k),obj.states_per_income,1)...
	                	.* Vn_k(:,indx_k), 2);
	            end

	            qk = obj.options.delta * u_k(:,kk) + Vn_k(:,kk) + obj.options.delta * Vkp_stacked;
	            if ~isempty(risk_adj)
	                qk = qk + obj.options.delta * risk_adj_k(:,kk);
	            end
	            
	            Vn1_k(:,kk) = Bik_all{kk} * qk;
	        end

	        % Howard improvement step
	        if (obj.current_iteration >= obj.options.HIS_start) && (~obj.p.SDU)
	            Vn1_k = obj.howard_improvement_step(ez_adj, Vn1_k, u_k, Bik_all);
	        end
	        Vn1 = reshape(Vn1_k, obj.p.nb, obj.p.na, obj.p.nz, obj.income.ny);
		end
	end

	methods (Access=private)
		function Bk = construct_Bk(obj, k, A, ez_adj)
		    % For the k-th income state, constructs the matrix
		    % Bk = (rho + deathrate - A)*delta + I, which serves
		    % as the divisor in the implicit-explicit update scheme.

		    if numel(obj.p.rhos) > 1
		        rhocol = kron(obj.p.rhos(:), ones(obj.p.nb*obj.p.na, 1));
		        rho_mat = spdiags(rhocol, obj.states_per_income, obj.states_per_income);
		    else
		        rho_mat = obj.p.rho * speye(obj.states_per_income);
		    end

		    indx_k = ~ismember(1:obj.income.ny,k);
		    i1 = 1+(k-1)*(obj.states_per_income);
		    i2 = k*(obj.states_per_income);

		    Ak = A(i1:i2, i1:i2);
		    Bk = obj.options.delta * rho_mat...
		    	+ (1 + obj.options.delta * obj.p.deathrate) * speye(obj.states_per_income)...
		        - obj.options.delta * Ak;

		    if obj.p.SDU
		        Bk = Bk - obj.options.delta...
		        	* spdiags(ez_adj(:, k, k), 0, obj.states_per_income, obj.states_per_income);
		    else
		        Bk = Bk - obj.options.delta * obj.income.ytrans(k, k)...
		        	* speye(obj.states_per_income);
		    end
		end

		function Vn2_k = howard_improvement_step(obj, ez_adj, Vn1_k, u_k, Bik_all)
		    % Technique to speed up convergence.

		    for jj = 1:obj.options.HIS_maxiters
		        Vn2_k = NaN(obj.states_per_income, obj.income.ny);
		        for kk = 1:obj.income.ny
		            indx_k = ~ismember(1:obj.income.ny, kk);
		            
		            if p.SDU == 1
		                Vkp_stacked = sum(squeeze(ez_adj(:, kk, indx_k)) .* Vn1_k(:, indx_k), 2);
		            else
		                Vkp_stacked = sum(...
		                	repmat(obj.income.ytrans(kk,indx_k),obj.states_per_income,1)...
		                	.* Vn1_k(:,indx_k), 2);
		            end
		            qk = obj.options.delta * u_k(:,kk) + Vn1_k(:,kk) + obj.options.delta * Vkp_stacked;
		            Vn2_k(:,kk) = Bik_all{kk} * qk;
		        end

		        dst = max(abs(Vn2_k(:) - Vn1_k(:)));
		        Vn1_k = Vn2_k;
		        if dst < obj.options.HIS_tol
		            break
		        end
    		end
		end
	end
end

function check_parameters(p)
	required_parameter_vars = {'nb', 'na', 'nz',...
			'rho', 'rhos', 'deathrate'};
	aux.check_for_required_properties(p, required_parameter_vars);
end

function check_income(income)
	required_income_vars = {'ny', 'ytrans'};
	aux.check_for_required_properties(income, required_income_vars);

	assert(income.ny > 0, "Must have ny >= 1");
	assert(ismatrix(income.ytrans), "Income transition matrix must be a matrix");
	assert(isequal(size(income.ytrans), [income.ny, income.ny]),...
		"Income transition matrix has different size than (ny, ny)");
end
