function out = extractBefore(str, pat)
%EXTRACTBEFORE Text before the first occurrence of a pattern (GNU Octave fallback).
%
%   Octave-only shim for MATLAB's EXTRACTBEFORE (text-pattern form only).
%   Added to the path by pf2_base.env.ensureOctaveCompat under Octave only.
%
%   Inputs:
%     str - char row or cellstr.
%     pat - char pattern.
%
%   Outputs:
%     out - Text preceding the first match; '' when there is no match.
%
%   See also: extractAfter, strfind

if iscell(str)
    out = cellfun(@(s) extractBefore(s, pat), str, 'UniformOutput', false);
    return;
end
k = strfind(str, pat);
if isempty(k)
    out = '';
else
    out = str(1:k(1) - 1);
end

end
