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
%     x    - Numeric array.
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
if nargin >= 3 && strcmpi(type, 'significant')
    error('pf2:octave:roundSignificant', ...
        'round(x, n, ''significant'') is not supported under Octave.');
end
scale = 10 .^ n;
y = builtin('round', x .* scale) ./ scale;

end
