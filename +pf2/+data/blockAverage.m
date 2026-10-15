function ga = blockAverage(segments, varargin)
% BLOCKAVERAGE Trial/grand average of epoched fNIRS segments onto a common grid
%
% Averages a cell array of epoched fNIRS structs (e.g. from
% pf2.data.extractBlocks) into a single grand-average waveform with mean,
% SEM, SD, N, min, and max per timepoint and channel. This is the one-call,
% single-subject equivalent of the group Experiment averaging path.
%
% Segments cut around event markers commonly share a sampling rate but start
% at different sub-sample phases, so their time vectors never line up.
% Calling grandAvgFNIRS on them directly then yields an almost entirely NaN
% average. blockAverage first resamples every segment onto one shared time
% grid (anchored at t=0, the SetT0 block onset) so the average is valid.
%
% Syntax:
%   ga = pf2.data.blockAverage(segments)
%   ga = pf2.data.blockAverage(segments, 'Name', Value)
%
% Inputs:
%   segments - Cell array {1 x N} of oxy-processed fNIRS structs, each with
%              .time and biomarker fields (.HbO, .HbR, ...). Typically the
%              output of pf2.data.extractBlocks (use its default SetT0 so the
%              segments are aligned to block onset at t=0). Empty cells are
%              ignored.
%
% Name-Value Parameters:
%   'ResampleInterval' - Sample interval in seconds for the shared output
%                        grid (default: [] = median of the segments' native
%                        sample intervals).
%   'AverageAux'       - Also average auxiliary signals present on the
%                        segments (default: false).
%   'HierarchyVars'    - Grouping matrix for hierarchical (nested) averaging,
%                        one row per (non-empty) segment (default: [] = flat
%                        average over all segments). See grandAvgFNIRS.
%
% Outputs:
%   ga - Grand-average struct. For each biomarker B in
%        {HbO, HbR, HbTotal, HbDiff, CBSI}:
%          ga.(B).Mean   [T x C] mean across segments
%          ga.(B).SEM    [T x C] standard error of the mean
%          ga.(B).SD     [T x C] standard deviation
%          ga.(B).N      [T x C] count of contributing segments
%          ga.(B).Median, ga.(B).Max, ga.(B).Min
%          ga.(B).data   [T x C x N] per-segment aligned data
%        Plus ga.time [T x 1], ga.units, and ga.info with hierarchy details.
%        Returns [] if there are no averageable segments.
%
% Algorithm:
%   1. Drop empty segments and pick a common sample interval (the median of
%      per-segment native intervals unless overridden).
%   2. Build a shared time grid anchored at t=0 spanning all segments.
%   3. Resample every segment onto that exact grid (pf2.data.resample with
%      'specifiedTimepoints'); timepoints outside a segment's range become
%      NaN and simply lower N there.
%   4. grandAvgFNIRS averages the now grid-aligned segments.
%
% Example:
%   data     = pf2.import.sampleData();              % recording with markers
%   proc     = processFNIRS2(data);
%   blocks   = pf2.data.defineBlocks(proc, 50, 15, 'Embed', false);
%   segments = pf2.data.extractBlocks(proc, blocks, ...
%                  'PreTime', 5, 'PostTime', 15, 'SetT0', true);
%   ga       = pf2.data.blockAverage(segments);
%   plot(ga.time, ga.HbO.Mean(:, 1));                % averaged HbO, channel 1
%
% See also: pf2.data.extractBlocks, pf2.data.defineBlocks,
%           exploreFNIRS.core.Experiment, grandAvgFNIRS

% Inputs are parsed with pf2_base.args rather than an arguments block so
% the function also runs under GNU Octave. Spec rows are {name, default,
% size, class, validators}.
opts = pf2_base.args.parse('blockAverage', varargin, {}, {
    'ResampleInterval', ([]), '', '', {@mustBeNumeric}
    'AverageAux',       (false), '', '', {}
    'HierarchyVars',    ([]), '', '', {@mustBeNumeric}
    });

pf2_base.ensureStatsFallbacks();  % ensure stats-toolbox fallbacks (nan*) are on the path before use

if ~iscell(segments)
    error('pf2:blockAverage:badInput', ...
        ['SEGMENTS must be a cell array of fNIRS structs ', ...
         '(e.g. the output of pf2.data.extractBlocks).']);
end

% Keep only non-empty segments (track indices for HierarchyVars alignment).
keep = find(~cellfun(@isempty, segments));
if isempty(keep)
    error('pf2:blockAverage:noSegments', 'No non-empty segments to average.');
end
segs = segments(keep);

% Resolve a common sample interval from the segments' native intervals.
ri = opts.ResampleInterval;
if isempty(ri)
    dts = nan(1, numel(segs));
    for i = 1:numel(segs)
        if isfield(segs{i}, 'time') && numel(segs{i}.time) > 1
            dts(i) = median(diff(segs{i}.time));
        end
    end
    dts = dts(isfinite(dts) & dts > 0);
    if isempty(dts)
        % No multi-sample segments (e.g. single-point GLM betas); defer to
        % grandAvgFNIRS without pre-gridding.
        hv = subsetHierarchy(opts.HierarchyVars, keep);
        ga = grandAvgFNIRS(segs, true, [], false, hv, false, logical(opts.AverageAux));
        return;
    end
    ri = median(dts);
end

% Build a shared grid anchored at t=0 (block onset under SetT0) spanning all
% segments, then resample every segment onto exactly that grid so their time
% vectors are identical and the average aligns sample-for-sample.
tmin = min(cellfun(@(s) min(s.time), segs));
tmax = max(cellfun(@(s) max(s.time), segs));
grid = unique([fliplr(0:-ri:(tmin - ri)), 0:ri:(tmax + ri)]);
grid = grid(grid >= tmin - 1e-9 & grid <= tmax + 1e-9);

for i = 1:numel(segs)
    if logical(opts.AverageAux)
        segs{i} = pf2.data.resample(segs{i}, 'specifiedTimepoints', grid, ...
            'averageAux', true, 'trimAux', true);
    else
        segs{i} = pf2.data.resample(segs{i}, 'specifiedTimepoints', grid);
    end
end

% Segments now share an identical grid; timeAlign=false and resampleSize=[]
% keep that grid and let grandAvgFNIRS match timepoints exactly.
hv = subsetHierarchy(opts.HierarchyVars, keep);
ga = grandAvgFNIRS(segs, false, [], false, hv, false, logical(opts.AverageAux));

end

function hv = subsetHierarchy(hierarchyVars, keep)
% Restrict a per-segment hierarchy matrix to the kept (non-empty) segments.
if isempty(hierarchyVars)
    hv = [];
elseif size(hierarchyVars, 1) >= max(keep)
    hv = hierarchyVars(keep, :);
else
    hv = hierarchyVars;  % size mismatch: pass through, let grandAvgFNIRS handle
end
end
