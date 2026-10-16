function y = round(x, n, type)
%ROUND Round with an optional digit count (GNU Octave fallback).
%
%   Octave's built-in ROUND accepts only ROUND(X). This shim adds MATLAB's
%   ROUND(X, N) (N decimal digits; negative N rounds left of the decimal
%   point) and ROUND(X, N, 'decimals'). It defers to the built-in for the
%   one-argument form. Added to the path by pf2_base.env.ensureOctaveCompat
%   under Octave only.
%
%   Inputs:
%     x    - Numeric array (double or single when n is given).
%     n    - (optional) Number of decimal digits.
%     type - (optional) 'decimals' (default). 'significant' is not
%            supported.
%
%   Outputs:
%     y - Rounded values, same size as x.
%
%   See also: floor, ceil, fix

if nargin < 2
    y = builtin('round', x);
    return;
end
if nargin >= 3
    if strcmpi(type, 'significant')
        error('pf2:octave:roundSignificant', ...
            'round(x, n, ''significant'') is not supported under Octave.');
    elseif ~strcmpi(type, 'decimals')
        error('MATLAB:round:InvalidRoundingType', ...
            'Rounding type must be ''decimals'' or ''significant''.');
    end
end
if ~isfloat(x)
    error('MATLAB:round:NonfloatMultipleArgs', ...
        'First argument must be double or single with more than one input.');
end
if ~(isnumeric(n) && isscalar(n) && isreal(n) && n == fix(n))
    error('MATLAB:round:SecondArg', ...
        'Number of digits must be an integer-valued scalar.');
end
n = double(n);
% Beyond the double range every value is unchanged (n large) or rounds to
% zero (n very negative); avoid 10^n overflowing to Inf.
if n > 308
    y = x;
    return;
elseif n < -308
    y = x .* 0;
    return;
end
% Single input is rounded in double precision and cast back.
isSingle = isa(x, 'single');
x = double(x);
if n >= 0
    scaled = x .* 10^n;
else
    scaled = x ./ 10^(-n);
end
y = builtin('round', scaled);
% Decimal ties such as 0.285 or 1.005 are stored slightly below the half
% point, so scaling lands one ulp under .5. MATLAB rounds these away from
% zero; do the same, only for positive n and below 2^52, where a one-ulp
% shortfall can come from the decimal representation.
frac = abs(scaled - fix(scaled));
tie = n > 0 & abs(frac - 0.5) <= eps(abs(scaled)) & frac < 0.5 & abs(scaled) < 2^52;
y(tie) = fix(scaled(tie)) + sign(scaled(tie));
if n >= 0
    y = y ./ 10^n;
else
    y = y .* 10^(-n);
end
% Where scaling overflowed, x has no digits at that position to round.
overflow = ~isfinite(scaled) & isfinite(x);
y(overflow) = x(overflow);
if isSingle
    y = single(y);
end

end
