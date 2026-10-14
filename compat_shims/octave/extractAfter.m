function out = extractAfter(str, pat)
%EXTRACTAFTER Text after the first occurrence of a pattern (GNU Octave fallback).
%
%   Octave-only shim for MATLAB's EXTRACTAFTER (text-pattern form only).
%   Added to the path by pf2_base.env.ensureOctaveCompat under Octave only.
%
%   Inputs:
%     str - char row or cellstr.
%     pat - char pattern.
%
%   Outputs:
%     out - Text following the first match; '' when there is no match.
%
%   See also: extractBefore, strfind

if iscell(str)
    out = cellfun(@(s) extractAfter(s, pat), str, 'UniformOutput', false);
    return;
end
k = strfind(str, pat);
if isempty(k)
    out = '';
else
    out = str(k(1) + numel(pat):end);
end

end
