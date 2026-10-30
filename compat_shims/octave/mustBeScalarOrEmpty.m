function mustBeScalarOrEmpty(value)
%MUSTBESCALAROREMPTY Validate that value is scalar or empty (GNU Octave fallback).
%
%   Octave-only shim for MATLAB's MUSTBESCALAROREMPTY. Added to the path by
%   pf2_base.env.ensureOctaveCompat under Octave only.
%
%   Inputs:
%     value - Value to validate.
%
%   Outputs:
%     (none) Errors with MATLAB:validators:mustBeScalarOrEmpty otherwise.
%
%   See also: isscalar, isempty

if ~(isscalar(value) || isempty(value))
    error('MATLAB:validators:mustBeScalarOrEmpty', 'Value must be scalar or empty.');
end

end
