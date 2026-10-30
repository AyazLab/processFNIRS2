function events = blocksToEvents(blocks, varargin)
% BLOCKSTOEVENTS Convert block definitions to GLM event structs
%
% Groups blocks by condition and collects onset times, durations, and
% amplitudes into the events struct format expected by buildDesignMatrix.
% This bridges defineBlocks (epoch-oriented) with the GLM pipeline.
%
% Syntax:
%   events = pf2.data.blocksToEvents(blocks)
%   events = pf2.data.blocksToEvents(blocks, 'GroupBy', 'Condition')
%
% Inputs:
%   blocks  - Struct array from pf2.data.defineBlocks with fields:
%             .startTime, .duration, .markerCode, .amplitude, .info
%
% Name-Value Parameters:
%   'GroupBy' - Field in blocks.info to group by (default: 'Condition').
%               If the field is missing from all blocks, falls back to
%               grouping by .markerCode.
%
% Outputs:
%   events - Struct array [1 x nConditions] with fields:
%            .name       - Condition label [char]
%            .onsets     - [1 x N] onset times in seconds
%            .duration   - [1 x N] durations (scalar if all equal)
%            .amplitude  - [1 x N] amplitudes (scalar if all equal)
%            .markerCode - Marker code(s) for this condition
%
% Algorithm:
%   1. Group blocks by the specified info field (or markerCode as fallback)
%   2. For each group: collect .startTime → .onsets, .duration → .duration,
%      .amplitude → .amplitude
%   3. Collapse duration/amplitude to scalar when all values are identical
%
% Example:
%   blocks = pf2.data.defineBlocks(data, [49, 50], 30, ...
%       'ConditionMap', {49, 'Easy'; 50, 'Hard'});
%   events = pf2.data.blocksToEvents(blocks);
%   [X, names] = pf2_base.fnirs.buildDesignMatrix(data.time, data.fs, events);
%
% See also: pf2.data.defineBlocks, pf2_base.fnirs.buildDesignMatrix,
%           pf2_base.fnirs.fitGLM

% Inputs are parsed with pf2_base.args rather than an arguments block so
% the function also runs under GNU Octave. Spec rows are {name, default,
% size, class, validators}.
blocks = pf2_base.args.check(blocks, '', '', {@(v) mustBeA(v, 'struct')}, 'Invalid argument at position 1.');
opts = pf2_base.args.parse('blocksToEvents', varargin, {}, {
    'GroupBy', ('Condition'), '', '', {}
    });

groupField = char(opts.GroupBy);

if isempty(blocks)
    events = struct('name', {}, 'onsets', {}, 'duration', {}, ...
        'amplitude', {}, 'markerCode', {});
    return;
end

% --- Determine grouping keys ---
useInfoField = false;
if isfield(blocks(1), 'info') && isfield(blocks(1).info, groupField)
    % Check that at least one block has a non-empty value
    for k = 1:length(blocks)
        if isfield(blocks(k).info, groupField) && ~isempty(blocks(k).info.(groupField))
            useInfoField = true;
            break;
        end
    end
end

if useInfoField
    % Group by info field
    keys = cell(length(blocks), 1);
    for k = 1:length(blocks)
        val = blocks(k).info.(groupField);
        if isnumeric(val)
            keys{k} = num2str(val);
        else
            keys{k} = char(val);
        end
    end
else
    % Fallback: group by markerCode
    keys = cell(length(blocks), 1);
    for k = 1:length(blocks)
        keys{k} = num2str(blocks(k).markerCode);
    end
end

% --- Build events per group ---
[uniqueKeys, ~, groupIdx] = unique(keys, 'stable');
nGroups = length(uniqueKeys);
events = repmat(struct('name', '', 'onsets', [], 'duration', [], ...
    'amplitude', [], 'markerCode', []), 1, nGroups);

for g = 1:nGroups
    mask = (groupIdx == g);
    groupBlocks = blocks(mask);

    events(g).name = uniqueKeys{g};
    events(g).onsets = [groupBlocks.startTime];
    events(g).duration = [groupBlocks.duration];
    events(g).amplitude = [groupBlocks.amplitude];
    events(g).markerCode = unique([groupBlocks.markerCode]);

    % Collapse to scalar if all identical
    if all(events(g).duration == events(g).duration(1))
        events(g).duration = events(g).duration(1);
    end
    if all(events(g).amplitude == events(g).amplitude(1))
        events(g).amplitude = events(g).amplitude(1);
    end
end

end
