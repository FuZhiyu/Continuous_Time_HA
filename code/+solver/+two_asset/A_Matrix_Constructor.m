classdef A_Matrix_Constructor < handle
    % This class constructs the A matrix for the HJB or KFE
    % First, instantiate the class with the required arguments,
    % then call the construct method with the policy functions
    % and value function as arguments.
    properties (SetAccess = protected)
        nb;
        na;
        nz;
        ny;
        dim;
       
        grids;
        p;

        asset_dB;
        asset_dF;
        asset_dSum;
        top;
        risk_term;
        shift;

        y_mat;

        modeltype;
    end

    methods
        %% --------------------------------------------------------------------
        % CLASS CONSTRUCTOR
        % ---------------------------------------------------------------------
        function obj = A_Matrix_Constructor(p, income, grids, modeltype)
            obj.nb = numel(grids.b.vec);
            obj.na = numel(grids.a.vec);
            obj.nz = p.nz;
            obj.ny = numel(income.y.vec);
            obj.dim = obj.nb * obj.na * obj.nz * obj.ny;

            obj.grids = grids;
            
            obj.p = p;

            obj.modeltype = modeltype;

            if strcmp(modeltype,'KFE')
                obj.y_mat = income.y.matrixKFE;
            elseif strcmp(modeltype,'HJB')
                obj.y_mat = income.y.matrix;
            end

            if p.sigma_r > 0
                obj.perform_returns_risk_computations();
            end
        end
        
        %% --------------------------------------------------------------------
        % COMPUTATIONS FOR RETURNS RISK
        % ---------------------------------------------------------------------
        function perform_returns_risk_computations(obj)
            obj.top = false(obj.nb, obj.na, obj.nz, obj.ny);
            if obj.p.OneAsset == 1
                obj.asset_dB = repmat(obj.grids.b.dB, [1 1 obj.nz obj.ny]);
                obj.asset_dF = repmat(obj.grids.b.dF, [1 1 obj.nz obj.ny]);

                obj.top(obj.nb, :, :, :) = true;

                obj.risk_term = (obj.grids.b.matrix * obj.p.sigma_r) .^ 2;

                obj.shift = 1;
            else
                obj.asset_dB = repmat(obj.grids.a.dB, [1 1 obj.nz obj.ny]);
                obj.asset_dF = repmat(obj.grids.a.dF, [1 1 obj.nz obj.ny]);

                obj.top(:, obj.na, :, :) = true;

                obj.risk_term = (obj.grids.a.matrix * obj.p.sigma_r) .^ 2;

                obj.shift = obj.nb;
            end

            obj.asset_dF(obj.top) = obj.asset_dB(obj.top);
            obj.asset_dSum = obj.asset_dB + obj.asset_dF;
        end

        %% --------------------------------------------------------------------
        % CONSTRUCT THE A MATRIX
        % ---------------------------------------------------------------------
        function [A, stationary] = construct(obj, model, V)
            nb = obj.nb;
            na = obj.na;
            nz = obj.nz;
            ny = obj.ny;
            dim = obj.dim;

            % policy functions
            s = model.s;
            d = model.d;

            stationary = [];

            %% ----------------------------------------------
            % INITIALIZE
            % -----------------------------------------------
            chi = NaN(nb,na,nz,ny);
            yy = NaN(nb,na,nz,ny);
            zetta = NaN(nb,na,nz,ny);

            X = NaN(nb,na,nz,ny);
            Y = NaN(nb,na,nz,ny);
            Z = NaN(nb,na,nz,ny);

            %% --------------------------------------------------------------------
            % COMPUTE ASSET DRIFTS
            % ---------------------------------------------------------------------
            if strcmp(obj.modeltype,'KFE')
                adriftB = min(d + obj.grids.a.matrix * (obj.p.r_a + obj.p.deathrate*obj.p.perfectannuities)...
                                                         + obj.p.directdeposit * obj.y_mat,0);
                adriftF = max(d + obj.grids.a.matrix * (obj.p.r_a + obj.p.deathrate*obj.p.perfectannuities)...
                                                         + obj.p.directdeposit * obj.y_mat,0);

                bdriftB = min(s - d - aux.two_asset.adj_cost_fn(d,obj.grids.a.matrix,obj.p),0);
                bdriftF = max(s - d - aux.two_asset.adj_cost_fn(d,obj.grids.a.matrix,obj.p),0);
            elseif strcmp(obj.modeltype,'HJB')
                adriftB = min(d,0) + min(obj.grids.a.matrix * (obj.p.r_a + obj.p.deathrate*obj.p.perfectannuities) + obj.p.directdeposit * obj.y_mat,0);
                adriftF = max(d,0) + max(obj.grids.a.matrix * (obj.p.r_a + obj.p.deathrate*obj.p.perfectannuities) + obj.p.directdeposit * obj.y_mat,0);

                bdriftB = min(-d - aux.two_asset.adj_cost_fn(d,obj.grids.a.matrix,obj.p),0) + min(s,0);
                bdriftF = max(-d - aux.two_asset.adj_cost_fn(d,obj.grids.a.matrix,obj.p),0) + max(s,0);    
            end

            %% --------------------------------------------------------------------
            % ILLIQUID ASSET TRANSITIONS
            % ---------------------------------------------------------------------
            chi(:,2:na,:,:) = -adriftB(:,2:na,:,:)./obj.grids.a.dB(:,2:na); 
            chi(:,1,:,:) = zeros(nb,1,nz,ny);
            yy(:,2:na-1,:,:) = adriftB(:,2:na-1,:,:)./obj.grids.a.dB(:,2:na-1) ...
                - adriftF(:,2:na-1,:,:)./obj.grids.a.dF(:,2:na-1); 
            yy(:,1,:,:) = - adriftF(:,1,:,:)./obj.grids.a.dF(:,1); 
            yy(:,na,:,:) = adriftB(:,na,:,:)./obj.grids.a.dB(:,na);
            zetta(:,1:na-1,:,:) = adriftF(:,1:na-1,:,:)./obj.grids.a.dF(:,1:na-1); 
            zetta(:,na,:,:) = zeros(nb,1,nz,ny);

            centdiag = reshape(yy,nb*na,nz,ny);
            lowdiag = reshape(chi,nb*na,nz,ny);
            lowdiag = circshift(lowdiag,-nb);
            updiag = reshape(zetta,nb*na,nz,ny);
            updiag = circshift(updiag,nb);  

            centdiag = reshape(centdiag,dim,1);
            updiag   = reshape(updiag,dim,1);
            lowdiag  = reshape(lowdiag,dim,1);

            A = spdiags(centdiag,0,dim,dim) ...
                + spdiags(updiag,nb,dim,dim)...
                + spdiags(lowdiag,-nb,dim,dim);

            %% --------------------------------------------------------------------
            % LIQUID ASSET TRANSITIONS
            % ---------------------------------------------------------------------
            X(2:nb,:,:,:) = - bdriftB(2:nb,:,:,:)./obj.grids.b.dB(2:nb,:); 
            X(1,:,:,:) = zeros(1,na,nz,ny);
            Y(2:nb-1,:,:,:) = bdriftB(2:nb-1,:,:,:)./obj.grids.b.dB(2:nb-1,:) ...
                - bdriftF(2:nb-1,:,:,:)./obj.grids.b.dF(2:nb-1,:); 
            Y(1,:,:,:) = - bdriftF(1,:,:,:)./obj.grids.b.dF(1,:); 
            Y(nb,:,:,:) = bdriftB(nb,:,:,:)./obj.grids.b.dB(nb,:);
            Z(1:nb-1,:,:,:) = bdriftF(1:nb-1,:,:,:)./obj.grids.b.dF(1:nb-1,:); 
            Z(nb,:,:,:) = zeros(1,na,nz,ny);

            centdiag = reshape(Y,nb*na,nz,ny);
            lowdiag = reshape(X,nb*na,nz,ny);
            lowdiag = circshift(lowdiag,-1);
            updiag = reshape(Z,nb*na,nz,ny);
            updiag = circshift(updiag,1);

            centdiag = reshape(centdiag,dim,1);
            updiag   = reshape(updiag,dim,1);
            lowdiag  = reshape(lowdiag,dim,1);

            A = A + spdiags(centdiag,0,dim,dim) ...
                + spdiags(updiag,1,dim,dim)...
                + spdiags(lowdiag,-1,dim,dim);
            
            %% --------------------------------------------------------------------
            % RATE OF RETURN RISK
            % ---------------------------------------------------------------------
            if (obj.p.sigma_r > 0) && (obj.p.OneAsset == 1) && (strcmp(obj.modeltype,'HJB')...
                || (strcmp(obj.modeltype,'KFE') && (obj.p.retrisk_KFE==1)))

                % Second derivative component, Vaa
                A = A + obj.compute_V_aa_terms(nb, na, nz, ny);

                if obj.p.SDU == 1
                    % First derivative component, Va
                    A = A + obj.compute_V_a_terms(nb, na, nz, ny, V, adriftB, adriftF);
                end

            elseif (obj.p.sigma_r > 0) && (obj.p.OneAsset == 0) && (strcmp(obj.modeltype,'HJB')...
                || (strcmp(obj.modeltype,'KFE') && (obj.p.retrisk_KFE==1)))

                % Second derivative component, Vaa
                A = A + obj.compute_V_aa_terms(nb, na, nz, ny);

                if obj.p.SDU == 1
                    % First derivative component, Va
                    [Arisk_Va, stationary] = obj.compute_V_a_terms(nb, na, nz, ny, V, adriftB, adriftF);
                    A = A + Arisk_Va;
                end     
            end
        end

        function Arisk_Vaa = compute_V_aa_terms(obj, nb, na, nz, ny)
            % This function computes the (1/2) * (a * sigma_r) ^2 * Vaa component
            % of the A matrix.

            % (1/2) * (a * sigma_r) ^ 2 * V_{i+1} * (dF*(dB+dF)/2)
            V_i_plus_1_term = obj.risk_term ./ (obj.asset_dF .* obj.asset_dSum);

            % - (1/2) * (a * sigma_r) ^ 2 * V_i * (1/dB + 1/dF) / ((dB+dF)/2)
            V_i_term = - obj.risk_term .* (1./obj.asset_dB + 1./obj.asset_dF) ./ obj.asset_dSum;
            
            % (1/2) * (a * sigma_r) ^ 2 * V_{i-1} * (dB*(dB+dF)/2)
            V_i_minus_1_term = obj.risk_term ./ (obj.asset_dB .* obj.asset_dSum);

            % impose V' = 0 at the top of the grid
            V_i_term(obj.top) = - obj.risk_term(obj.top) ./ (obj.asset_dB(obj.top) .* obj.asset_dSum(obj.top));
            V_i_plus_1_term(obj.top) = 0;

            % shift entries to put on the A matrix diagonals in accordance with spdiags algorithm
            V_i_plus_1_term = circshift(reshape(V_i_plus_1_term, nb*na, nz, ny), obj.shift);
            V_i_minus_1_term = circshift(reshape(V_i_minus_1_term, nb*na, nz, ny), -obj.shift);

            Arisk_Vaa = spdiags(V_i_plus_1_term(:), obj.shift, obj.dim, obj.dim)...
                    + spdiags(V_i_term(:), 0, obj.dim, obj.dim)...
                    + spdiags(V_i_minus_1_term(:), -obj.shift, obj.dim, obj.dim);
        end

        function [Arisk_Va, stationary] = compute_V_a_terms(obj, nb, na,...
            nz, ny, V, driftB, driftF)

            assert(obj.p.SDU == 1, "This term only applies to SDU.")

            V1B = zeros(nb, na, nz, ny);
            V1F = zeros(nb, na, nz, ny);
            
            if obj.p.OneAsset == 1
                V1B(2:nb,:,:,:) = (V(2:nb,:,:,:) - V(1:nb-1,:,:,:)) ./ obj.grids.b.dB(2:nb, :);
                V1F(1:nb-1,:,:,:) = (V(2:nb,:,:,:) - V(1:nb-1,:,:,:)) ./ obj.grids.b.dF(1:nb-1, :);
            else
                V1B(:,2:na,:,:) = (V(:,2:na,:,:) - V(:,1:na-1,:,:)) ./ obj.grids.a.dB(:,2:na);
                V1F(:,1:na-1,:,:) = (V(:,2:na,:,:) - V(:,1:na-1,:,:)) ./ obj.grids.a.dF(:,1:na-1);
            end

            V1 = (driftB < 0) .* V1B + (driftF > 0) .* V1F;

            % some states may have no drift, will need to deal with them separately
            % by adding to the RHS of HJB
            stationary = (driftB >= 0) & (driftF <= 0);

            % now add zeta(a) * Va^2 term
            if obj.p.invies == 1
                adj_term = obj.risk_term .* V1 * (1 - obj.p.riskaver);
            else
                adj_term = obj.risk_term .* V1 ./ V * (obj.p.invies - obj.p.riskaver) / (1 - obj.p.invies);
            end

            updiag = zeros(nb, na, nz, ny);
            lowdiag = zeros(nb, na, nz, ny);
            centdiag = zeros(nb, na, nz, ny);

            lowdiag(driftB < 0) = - adj_term(driftB < 0) ./ obj.asset_dB(driftB < 0);
            updiag(driftF > 0) = adj_term(driftF > 0) ./ obj.asset_dF(driftF > 0);

            if obj.p.OneAsset == 1
                lowdiag(1, :, :, :) = 0;
                updiag(nb, :, :, :) = 0;
            else
                lowdiag(:, 1, :, :) = 0;
                updiag(:, na, :, :) = 0;
            end
            centdiag = - lowdiag - updiag;

            
            lowdiag = circshift(reshape(lowdiag, nb*na, nz, ny), -nb);
            updiag = circshift(reshape(updiag, nb*na, nz, ny), nb);

            Arisk_Va = spdiags(centdiag(:), 0, obj.dim, obj.dim) ...
                        + spdiags(updiag(:), obj.shift, obj.dim, obj.dim) ...
                        + spdiags(lowdiag(:), -obj.shift, obj.dim, obj.dim);
        end
    end
end