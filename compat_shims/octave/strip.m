function out = strip(str, side, stripChar)
%STRIP Remove leading and/or trailing characters (GNU Octave fallback).
%
%   Octave-only shim for MATLAB's STRIP. Added to the path by
%   pf2_base.env.ensureOctaveCompat under Octave only.
%
%   Inputs:
%     str       - char row or cellstr.
%     side      - (optional) 'both' (default), 'left', or 'right'.
%     stripChar - (optional) Single character to remove. Default removes
%                 whitespace.
%
%   Outputs:
%     out - Stripped text, same type as str.
%
%   See also: strtrim, deblank

if nargin < 2 || isempty(side)
    side = 'both';
end
if nargin < 3
    stripChar = '';
end

if iscell(str)
    out = cellfun(@(s) stripOne(s, side, stripChar), str, 'UniformOutput', false);
else
    out = stripOne(str, side, stripChar);
end

end

function s = stripOne(s, side, stripChar)
% STRIPONE Strip a single char row.
if isempty(stripChar)
    keep = ~isspace(s);
else
    keep = s ~= stripChar;
end
first = find(keep, 1, 'first');
last  = find(keep, 1, 'last');
if isempty(first)
    s = s([]);
    return;
end
switch lower(side)
    case 'left'
        s = s(first:end);
    case 'right'
        s = s(1:last);
    otherwise
        s = s(first:last);
end
end
