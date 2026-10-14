function tf = contains(str, pat, varargin)
%CONTAINS True where a string contains a pattern (GNU Octave fallback).
%
%   Octave-only shim for MATLAB's CONTAINS, which core Octave does not
%   provide. pf2_base.env.ensureOctaveCompat adds this folder to the path
%   under Octave only; MATLAB never sees it.
%
%   Inputs:
%     str      - char, cellstr, or string array to search.
%     pat      - char, cellstr, or string array of patterns. True when any
%                pattern occurs.
%     varargin - Optional 'IgnoreCase', logical (default false).
%
%   Outputs:
%     tf - Logical scalar for char input, otherwise logical array the size
%          of str.
%
%   See also: strfind, startsWith, endsWith

ignoreCase = false;
for k = 1:2:numel(varargin)
    if strcmpi(varargin{k}, 'IgnoreCase')
        ignoreCase = logical(varargin{k+1});
    end
end

isCharInput = ischar(str);
str = toCell(str);
pat = toCell(pat);
if ignoreCase
    str = lower(str);
    pat = lower(pat);
end

tf = false(size(str));
for i = 1:numel(str)
    for j = 1:numel(pat)
        if ~isempty(strfind(str{i}, pat{j}))
            tf(i) = true;
            break;
        end
    end
end
if isCharInput
    tf = tf(1);
end

end

function c = toCell(x)
% TOCELL Normalize char/cellstr/string input to a cellstr.
if ischar(x)
    c = {x};
elseif iscell(x)
    c = x;
else
    c = cellstr(x);
end
end
