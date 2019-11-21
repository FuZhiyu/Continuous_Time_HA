function [V, gg] = make_initial_guess(p, grids, gridsKFE, income)
    % makes initial guesses for the value function and distribution

    % Parameters
    % ----------
    % p : a Params object
    %
    % grids : a Grid object which holds the HJB grids
    %
    % gridsKFE : a Grid object which holds the KFE grids
    %
    % income : an Income object
    %
    % Returns
    % -------
    % V : value function guess, of shape (nb, na, nz, ny)
    %
    % gg : distribution guess, of shape (nb_KFE, na_KFE, nz, ny)

	nb = p.nb;
	na = p.na;
	nz = p.nz;
	ny = income.ny;

	dim = nb * na * nz * ny;

    %% --------------------------------------------------------------------
    % GUESS FOR VALUE FUNCTION
    % ---------------------------------------------------------------------
	rho_mat = p.rho * speye(dim);

	% liquid returns grid
	r_b_mat = p.r_b .* (grids.b.matrix>=0) +  p.r_b_borr .* (grids.b.matrix<0);

	% consumption guess
	r_b_mat_adj = r_b_mat;
	r_b_mat_adj(r_b_mat<=0.001) = 0.001; % mostly for r_b <= 0, enforce a reasonable guess
    r_a_adj = (p.r_a <= 0.001) * 0.001 + (p.r_a > 0.001) * p.r_a;
	c_0 = (1-p.directdeposit - p.wagetax) * income.y.matrix ...
            + (r_a_adj + p.deathrate*p.perfectannuities) * grids.a.matrix...
            + (r_b_mat_adj + p.deathrate*p.perfectannuities) .* grids.b.matrix + p.transfer;

    if p.SDU == 1
        u = p.rho * aux.u_fn(c_0, p.invies);
    else
        u = aux.u_fn(c_0, p.riskaver);
    end

    if p.SDU == 1
        % risk-adjust income transitions
        ez_adj = income.SDU_income_risk_adjustment(p, u);
    else
        ez_adj = [];
    end
    inctrans = income.sparse_income_transitions(p, ez_adj, 'HJB');

    if p.sigma_r > 0
        % Vaa term
        deltas = grids.a.dB + grids.a.dF;
        deltas(:, 1) = 2 * grids.a.dF(:, 1);
        deltas(:, na) = 2 * grids.a.dB(:, na);

        updiag = zeros(nb, na, nz, ny);
        centdiag = zeros(nb, na, nz, ny);
        lowdiag = zeros(nb, na, nz, ny);
        
        updiag(:, 1:na-1, :, :) = repmat(1 ./ grids.a.dF(:, 1:na-1), [1 1 nz ny]);

        centdiag(:, 1:na-1, :, :) = - repmat(1 ./ grids.a.dF(:, 1:na-1) + 1 ./ grids.a.dB(:, 1:na-1), [1 1 nz ny]);
        centdiag(:, na, :, :) = - repmat(1 ./ grids.a.dB(:, na), [1 1 nz ny]);

        lowdiag(:, 1:na-1, :, :) = repmat(1 ./ grids.a.dB(:, 1:na-1), [1 1 nz ny]);
        lowdiag(:, na, :, :) = repmat(1 ./ grids.a.dB(:, na), [1 1 nz ny]);
        
        updiag(:, 1, :, :) = 0;
        centdiag(:, 1, :, :) = 0;
        lowdiag(:, 1, :, :) = 0;

        risk_adj = (grids.a.matrix .* p.sigma_r) .^ 2;

        updiag = risk_adj .* updiag ./ deltas;
        centdiag = risk_adj .* centdiag ./ deltas;
        lowdiag = risk_adj .* lowdiag ./ deltas;

        updiag = circshift(reshape(updiag, nb*na, nz, ny), nb);
        lowdiag = circshift(reshape(lowdiag, nb*na, nz, ny), -nb);

        Arisk = spdiags(updiag(:), nb, dim, dim)...
        	+ spdiags(centdiag(:), 0, dim, dim)...
        	+ spdiags(lowdiag(:), -nb, dim, dim);
    else
        Arisk = sparse(dim, dim);
    end

    V = (rho_mat - inctrans - Arisk) \ u(:);
    V = reshape(V, nb, na, nz, ny);

    %% --------------------------------------------------------------------
    % GUESS FOR EQUILIBRIUM DISTRIBUTION
    % ---------------------------------------------------------------------
    gg0 = ones(p.nb_KFE,p.na_KFE,p.nz,income.ny);
    gg0 = gg0 .* permute(repmat(income.ydist,[1 p.nb_KFE p.na_KFE p.nz]),[2 3 4 1]);
    if p.OneAsset == 1
        gg0(:,gridsKFE.a.vec>0,:,:) = 0;
    end
    gg0 = gg0 / sum(gg0(:));
    gg0 = gg0 ./ gridsKFE.trapezoidal.matrix;
    gg = gg0;

end