function mustBeTextScalar(value)
%MUSTBETEXTSCALAR Validate that value is a single piece of text (GNU Octave fallback).
%
%   Octave-only shim for MATLAB's MUSTBETEXTSCALAR: passes for a char row
%   vector (including '') or a string scalar. Added to the path by
%   pf2_base.env.ensureOctaveCompat under Octave only.
%
%   Inputs:
%     value - Value to validate.
%
%   Outputs:
%     (none) Errors with MATLAB:validators:mustBeTextScalar otherwise.
%
%   See also: mustBeText

ok = (ischar(value) && (isrow(value) || isequal(size(value), [0 0]))) || ...
    (isa(value, 'string') && isscalar(value));
if ~ok
    error('MATLAB:validators:mustBeTextScalar', ...
        'Value must be a character vector or string scalar.');
end

end
