function tf = isStringScalar(x)
%ISSTRINGSCALAR True for a 1x1 string object (GNU Octave fallback).
%
%   Octave-only shim for MATLAB's ISSTRINGSCALAR. Added to the path by
%   pf2_base.env.ensureOctaveCompat under Octave only.
%
%   Inputs:
%     x - Any value.
%
%   Outputs:
%     tf - Logical scalar; true when x is a string scalar.
%
%   See also: isstring, ischar

tf = isa(x, 'string') && isscalar(x);

end
