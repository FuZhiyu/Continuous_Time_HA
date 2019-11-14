function x = risk_premium_calibrator(returns, runopts, p)
	% This function solves the model for given values of
	% liquid returns and illiquid returns

	% Set new values for returns
	new_rb = 0.035*(returns(1))/(1+abs(returns(1)));
	new_ra = new_rb + 0.04 * abs(returns(2)) / (1 + abs(returns(2)));
	p.reset("r_b", new_rb);
    p.reset("r_a", new_ra);
	fprintf("r_b has been reset to %f...\n", p.r_b);
	fprintf("r_a has been reset to %f...\n", p.r_a);
	
	% Solve model
	stats = main_two_asset(runopts, p);

	% Compute distance from target
	x = (stats.liqw - 0.5) ^ 2;
	x(2) = (stats.totw - p.targetAY) ^ 2;

    fprintf("For r_b = %f", p.r_b);
	fprintf(" and r_a = %f:\n", p.r_a);
	fprintf("Liquid wealth = %f\n", stats.liqw);
	fprintf("Total wealth = %f\n", stats.totw);

end