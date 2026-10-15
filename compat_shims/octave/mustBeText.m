function mustBeText(value)
%MUSTBETEXT Validate that value is text (GNU Octave fallback).
%
%   Octave-only shim for MATLAB's MUSTBETEXT: passes for a char array, a
%   cell array of char vectors, or a string array. Added to the path by
%   pf2_base.env.ensureOctaveCompat under Octave only.
%
%   Inputs:
%     value - Value to validate.
%
%   Outputs:
%     (none) Errors with MATLAB:validators:mustBeText when value is not text.
%
%   See also: mustBeTextScalar

if ~(ischar(value) || iscellstr(value) || isa(value, 'string'))
    error('MATLAB:validators:mustBeText', ...
        'Value must be text (a character vector, cell array of character vectors, or string array).');
end

end
