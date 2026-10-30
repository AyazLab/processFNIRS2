function n = strlength(str)
%STRLENGTH Number of characters in each string (GNU Octave fallback).
%
%   Octave-only shim for MATLAB's STRLENGTH. Added to the path by
%   pf2_base.env.ensureOctaveCompat under Octave only.
%
%   Inputs:
%     str - char row, cellstr, or string array.
%
%   Outputs:
%     n - Character count; a scalar for char input, otherwise an array the
%         size of str.
%
%   See also: numel, length

if ischar(str)
    n = numel(str);
else
    n = cellfun(@numel, cellstr(str));
end

end
