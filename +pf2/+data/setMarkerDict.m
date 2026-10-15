function data = setMarkerDict(data, dict, varargin)
% SETMARKERDICT Set or merge the dataset's marker dictionary
%
% Stores a canonical code->label dictionary at data.info.markerDict so that
% labelMarkers, defineBlocks, and plotting can give marker codes meaning.
% By default the supplied entries are merged into any existing dictionary
% (new entries win on Code conflicts); pass 'Merge', false to replace it.
%
% Syntax:
%   data    = pf2.data.setMarkerDict(data, dict)
%   data    = pf2.data.setMarkerDict(data, {code,'Label'; ...})
%   data    = pf2.data.setMarkerDict(data, dict, 'Merge', false)
%   allData = pf2.data.setMarkerDict(allData, dict)        % cell array
%
% Inputs:
%   data - fNIRS data struct or a cell array of structs.
%   dict - Dictionary as a table, {code,'Label'} cell array, or
%          containers.Map (normalized via pf2_base.normalizeMarkerDict).
%
% Name-Value Parameters:
%   'Merge' - Merge with the existing dictionary (default: true). When false,
%             the supplied dictionary replaces any existing one.
%
% Outputs:
%   data - Input with data.info.markerDict set to the canonical dictionary.
%
% Algorithm:
%   1. Cell array  -> apply recursively to each element.
%   2. Normalize the supplied dictionary via pf2_base.normalizeMarkerDict.
%   3. Ensure data.info exists, then either merge with the existing dictionary
%      (Merge=true, the default) or replace it (Merge=false). On a merge, the
%      call is mergeMarkerDict(newDict, existing) so the SUPPLIED entries win
%      on Code conflicts while previously-set codes are retained.
%
% Notes:
%   - Merge direction is "new wins": re-setting a code updates its label and
%     leaves other codes untouched. Use 'Merge', false to discard the old
%     dictionary entirely.
%   - The dictionary is dataset-level metadata (info.markerDict); it does not
%     alter the markers table. Use labelMarkers to stamp labels onto markers.
%
% Example:
%   data = pf2.data.setMarkerDict(data, {49,'Stroop'; 50,'Control'});
%   data = pf2.data.setMarkerDict(data, extra, 'Merge', true);
%
% See also: pf2.data.getMarkerDict, pf2.data.labelMarkers,
%           pf2_base.normalizeMarkerDict

% Inputs are parsed with pf2_base.args rather than an arguments block so
% the function also runs under GNU Octave. Spec rows are {name, default,
% size, class, validators}.
opts = pf2_base.args.parse('setMarkerDict', varargin, {}, {
    'Merge', (true), '1,1', 'logical', {}
    });

% Cell array: apply to each element
if iscell(data)
    fwd = namedargs2cell(opts);
    for ci = 1:numel(data)
        data{ci} = pf2.data.setMarkerDict(data{ci}, dict, fwd{:});
    end
    return;
end

doMerge = opts.Merge;

if ~isstruct(data)
    error('pf2:setMarkerDict:badInput', ...
        'First argument must be an fNIRS struct or a cell array of structs.');
end

newDict = pf2_base.normalizeMarkerDict(dict);

if ~isfield(data, 'info') || ~isstruct(data.info)
    data.info = struct();
end

if doMerge && isfield(data.info, 'markerDict') && ~isempty(data.info.markerDict)
    % New entries win on Code conflicts
    data.info.markerDict = pf2_base.mergeMarkerDict(newDict, data.info.markerDict);
else
    data.info.markerDict = newDict;
end

end
