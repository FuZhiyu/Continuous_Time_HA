function [AYdiff,HJB,KFE,Au] = solver(runopts,p,income,grd,grdKFE)
	% Solve for the steady state via the HJB and KFE equations, then
	% compute some relevant statistics.

    % keep track of number of mean asset iterations
	persistent iterAY
	if strcmp(runopts.RunMode,'Iterate') && isempty(iterAY)
		iterAY = 1;
	elseif strcmp(runopts.RunMode,'Iterate') && ~isempty(iterAY)
		iterAY = iterAY + 1;
	end

	fprintf('Solving for rho = %7.7f\n',p.rho)

    na = p.na;
    nb = p.nb;
	na_KFE = p.na_KFE;
	nb_KFE = p.nb_KFE;
	ny = numel(income.y.vec);
	nz = p.nz;

	% Create interpolation matrix between KFE grid and regular grid
	interp_decision = aux.interpTwoD(grdKFE.b.vec,grdKFE.a.vec,grd.b.vec,grd.a.vec);
	interp_decision = kron(speye(ny*nz),interp_decision);

	% Returns grid
	r_b_mat = p.r_b .* (grd.b.matrix>=0) +  p.r_b_borr .* (grd.b.matrix<0);

	%% --------------------------------------------------------------------
	% INITIALIZATION FOR HJB
	% ---------------------------------------------------------------------
	if numel(p.rhos) > 1
		rho_mat = reshape(p.rhos,[1 1 numel(p.rhos)]);
	else
		rho_mat =  p.rho;
	end

	% Initial guess

    	% Attempt at more accurate guess
    Vn = solver.value_guess(p, grd, income);

	% Initial distribution
    gg0 = ones(nb_KFE,na_KFE,nz,ny);
    gg0 = gg0 .* permute(repmat(income.ydist,[1 nb_KFE na_KFE nz]),[2 3 4 1]);
    if p.OneAsset == 1
        gg0(:,grdKFE.a.vec>0,:,:) = 0;
    end
    gg0 = gg0 / sum(gg0(:));
	gg0 = gg0 ./ grdKFE.trapezoidal.matrix;
	gg = gg0;

	%% --------------------------------------------------------------------
    % SOLVE HJB
	% ---------------------------------------------------------------------
	% Check if maximum number of iterations has been exceeded
	if iterAY > p.maxit_AY
		msgID = 'RHOITERATION:MaxIterExceeded';
	    msg = 'RHOITERATION:MaxIterExceeded';
	    iterException = MException(msgID,msg);
	    throw(iterException)
    end

    A_Constructor = solver.A_Matrix_Constructor(p, income, grd, 'HJB');

    fprintf('    --- Iterating over HJB ---\n')
    dst = 1e5;
	for nn	= 1:p.maxit_HJB
	  	[HJB, V_deriv_risky_asset_nodrift] = solver.find_policies(p,income,grd,Vn);

	    % CONSTRUCT TRANSITION MATRIX 
        [A, stationary] = A_Constructor.construct(HJB, Vn);

        if ~isempty(stationary)
        	% this block will only be executed if SDU == 1 and sigma_r > 0
        	%
        	% there are states with neither backward nor forward drift,
        	% need to compute additional term for risk
        	if p.invies == 1
        		risk_adj = (1-p.riskaver) * V_deriv_risky_asset_nodrift .^ 2;
        	else
        		risk_adj = V_deriv_risky_asset_nodrift .^ 2 ./ Vn * (p.invies - p.riskaver) / (1-p.invies);
    		end

    		risk_adj = risk_adj .* (grd.a.matrix * p.sigma_r) .^ 2 / 2;
    		risk_adj(~stationary) = 0;
    	else
    		risk_adj = [];
    	end
        
		% UPDATE VALUE FUNCTION
		Vn1 = solver.solveHJB(p, A, income, Vn, HJB.u, nn, risk_adj);

	    % CHECK FOR CONVERGENCE
	    Vdiff = Vn1 - Vn;
	    Vn = Vn1;
	    dst = max(abs(Vdiff(:)));
        if (nn==1) || (mod(nn,25)==0)
	    	fprintf('\tHJB iteration = %i, distance = %e\n',nn,dst);
        end

        if dst<p.crit_HJB
	        fprintf('\tHJB converged after %i iterations\n',nn);
		 	break
		elseif dst>10 && nn>500
		 	% Not going to converge, throw exception
		 	msgID = 'HJB:NotConverging';
		    msg = 'HJB:NotConverging';
		    HJBException = MException(msgID,msg);
		    throw(HJBException)
		end
    end
    
    if (nn >= p.maxit_HJB)
        error("HJB didn't converge");
    end
    
    % STORE VALUE FUNCTION AND POLICIES ON BOTH GRIDS
    HJB.Vn = Vn;
    KFE_Vn = reshape(interp_decision*Vn(:),nb_KFE,na_KFE,nz,ny);
    KFE = solver.find_policies(p,income,grdKFE,KFE_Vn);
    KFE.Vn = KFE_Vn;

	%% --------------------------------------------------------------------
    % SOLVE KFE
	% ---------------------------------------------------------------------
    A_Constructor_KFE = solver.A_Matrix_Constructor(p, income, grdKFE, 'KFE');
    Au = A_Constructor_KFE.construct(KFE, KFE.Vn);
    

    dim2Identity = 'a';
	g = solver.solveKFE(p,income,grdKFE,gg,Au,dim2Identity);

	%% --------------------------------------------------------------------
	% COMPUTE WEALTH
	% ---------------------------------------------------------------------
	Eillwealth = (g(:) .* grdKFE.trapezoidal.matrix(:))' * grdKFE.a.matrix(:);
	Eliqwealth = (g(:) .* grdKFE.trapezoidal.matrix(:))' * grdKFE.b.matrix(:);
	Etotwealth = Eillwealth + Eliqwealth;
    
    KFE.g = g;

	AYdiff = Etotwealth - p.targetAY;
	fprintf('    --- MEAN WEALTH = %f ---\n\n',Etotwealth)
    
end