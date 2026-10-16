function [data, blocks] = experiment(stage)
% EXPERIMENT Generate a synthetic multi-subject fNIRS experiment
%
% Creates a realistic multi-subject dataset from the fNIR2000 sample data
% with event markers, auxiliary signals, and behavioral metadata. Returns
% data at one of four processing stages to demonstrate the typical fNIRS
% analysis workflow.
%
% Stages:
%   'raw'       - Full ~1118s recordings per subject with markers, aux, and
%                 subject-level info. Returns cell array of 4 subject structs.
%   'blocks'    - Same raw data plus block definitions with per-block
%                 behavioral data. Second output is a cell array of block
%                 struct arrays (one per subject).
%   'extracted' - Block segments extracted with 10s pre-time for baseline.
%                 Returns cell array of 24 segments (4 subjects x 6 blocks).
%   'aligned'   - Same as 'extracted' but time-centered so block onset = 0.
%                 Ready to feed directly into Experiment. (default)
%
% Syntax:
%   allData = pf2.import.sampleData.experiment()
%   allData = pf2.import.sampleData.experiment('aligned')
%   subjects = pf2.import.sampleData.experiment('raw')
%   [subjects, blockDefs] = pf2.import.sampleData.experiment('blocks')
%   segments = pf2.import.sampleData.experiment('extracted')
%
% Inputs:
%   stage - Processing stage to return (default: 'aligned')
%           One of: 'raw', 'blocks', 'extracted', 'aligned'
%
% Outputs:
%   data   - Cell array of fNIRS structs. Contents depend on stage:
%            'raw'/'blocks': {1 x 4} subject recordings
%            'extracted'/'aligned': {1 x 24} block segments (4 subjects x 6 blocks)
%   blocks - Cell array of block struct arrays (from defineBlocks).
%            Only populated for 'blocks', 'extracted', and 'aligned'.
%
% Experiment Design:
%   4 subjects (2 Young, 2 Older), each with a ~1118s recording containing:
%     - 6 blocks: 2 Easy (marker 10), 2 Hard (marker 20), 2 Rest (marker 30)
%     - Block order is randomized per subject (counterbalanced)
%     - Nominal onsets ~60s, 200s, 340s, 520s, 700s, 880s with +/-8s jitter
%     - Block duration: 30s each
%     - Aux signals: 3-axis accelerometer (g), heart rate (bpm)
%     - Behavioral: reactionTime (ms), accuracy (proportion), taskLoad
%       (Rest blocks have NaN for reactionTime and accuracy)
%
% Example:
%   % Full workflow from raw to analysis
%   subjects = pf2.import.sampleData.experiment('raw');
%   fprintf('Subject 1 time range: %.0f-%.0fs\n', ...
%       min(subjects{1}.time), max(subjects{1}.time));
%
%   % Quick start - aligned segments ready for Experiment
%   allData = pf2.import.sampleData.experiment();
%   ex = exploreFNIRS.core.Experiment(allData);
%   ex.select('Condition', {'Easy', 'Hard'});  % exclude Rest
%   ex.groupby({'Condition'});
%   ex.aggregate();
%
%   % Include all conditions (Easy, Hard, Rest)
%   ex2 = exploreFNIRS.core.Experiment(allData);
%   ex2.groupby({'Condition'});
%   ex2.aggregate();
%
% See also: pf2.import.sampleData.fNIR2000, pf2.data.defineBlocks,
%           pf2.data.extractBlocks, exploreFNIRS.core.Experiment

if nargin < 1
    stage = 'aligned';
end
stage = validatestring(stage, {'raw', 'blocks', 'extracted', 'aligned'});

% Process sample data once
raw = pf2.import.sampleData('fNIR2000');  % by-name form also works under Octave
processed = processFNIRS2(raw);

% Experiment parameters
rng(42);
nSubjects = 4;
subjectIDs  = {'Sub01', 'Sub02', 'Sub03', 'Sub04'};
groupLabels = {'Young', 'Young', 'Older', 'Older'};
ages = [22, 25, 55, 60];

% Block design: 6 blocks, 3 conditions
% Each subject gets a shuffled block order and jittered onset times
EASY = 10;
HARD = 20;
REST = 30;
baseOnsets     = [60, 200, 340, 520, 700, 880];
blockDuration  = 30;
nBlocks        = length(baseOnsets);
conditionMap   = {EASY, 'Easy'; HARD, 'Hard'; REST, 'Rest'};
onsetJitterSD  = 8;  % seconds of jitter around nominal onset

% Condition pool: 2 Easy, 2 Hard, 2 Rest (shuffled per subject)
conditionPool = [EASY, EASY, HARD, HARD, REST, REST];

% --- Build raw subjects ---
subjects = cell(1, nSubjects);
for s = 1:nSubjects
    d = processed;

    % Subject-level info
    d.info.SubjectID = subjectIDs{s};
    d.info.Group     = groupLabels{s};
    d.info.Age       = ages(s);

    % Shuffle block order and jitter onsets for this subject
    blockCodes  = conditionPool(randperm(nBlocks));
    blockOnsets = baseOnsets + round(onsetJitterSD * randn(1, nBlocks));
    blockOnsets = max(blockOnsets, 20);  % keep away from recording start

    % Event markers: [time, code, duration]
    d.markers = pf2_base.normalizeMarkers([blockOnsets(:), blockCodes(:), repmat(blockDuration, nBlocks, 1)]);

    % Aux: heart rate (continuous with task-related modulation)
    nSamples = length(d.time);
    baseHR = 68 + (s - 1) * 3 + randn;
    hr = baseHR + 2 * randn(nSamples, 1);
    for b = 1:nBlocks
        tMask = d.time >= blockOnsets(b) & ...
                d.time <= blockOnsets(b) + blockDuration;
        if blockCodes(b) == HARD
            hr(tMask) = hr(tMask) + 12;
        elseif blockCodes(b) == EASY
            hr(tMask) = hr(tMask) + 5;
        end
        % Rest: no HR modulation (stays at baseline)
    end
    d.Aux.heartRate.data = hr;
    d.Aux.heartRate.time = d.time;
    d.Aux.heartRate.unit = 'bpm';
    d.Aux.heartRate.varNames = {'HR'};

    % Aux: 3-axis accelerometer (more motion during hard blocks)
    accel = 0.01 * randn(nSamples, 3);
    for b = 1:nBlocks
        tMask = d.time >= blockOnsets(b) & ...
                d.time <= blockOnsets(b) + blockDuration;
        if blockCodes(b) == HARD
            accel(tMask, :) = accel(tMask, :) + 0.05 * randn(sum(tMask), 3);
        end
        % Easy and Rest: minimal motion (stays at baseline noise)
    end
    d.Aux.accelerometer.data = accel;
    d.Aux.accelerometer.time = d.time;
    d.Aux.accelerometer.unit = 'g';
    d.Aux.accelerometer.varNames = {'X', 'Y', 'Z'};

    subjects{s} = d;
end

if strcmp(stage, 'raw')
    data = subjects;
    blocks = {};
    return;
end

% --- Define blocks with behavioral data ---
allBlocks = cell(1, nSubjects);
for s = 1:nSubjects
    blk = pf2.data.defineBlocks(subjects{s}, [EASY, HARD, REST], blockDuration, ...
        'ConditionMap', conditionMap, 'Embed', false);

    % Add per-block behavioral measures
    baseRT = 300 + (s - 1) * 20;
    for b = 1:length(blk)
        if blk(b).markerCode == HARD
            blk(b).info.reactionTime = baseRT + 150 + randn * 30;
            blk(b).info.accuracy     = 0.70 + randn * 0.05;
            blk(b).info.taskLoad     = 3;
        elseif blk(b).markerCode == EASY
            blk(b).info.reactionTime = baseRT + randn * 20;
            blk(b).info.accuracy     = 0.95 + randn * 0.02;
            blk(b).info.taskLoad     = 1;
        else  % REST
            blk(b).info.reactionTime = NaN;
            blk(b).info.accuracy     = NaN;
            blk(b).info.taskLoad     = 0;
        end
    end
    allBlocks{s} = blk;
end

if strcmp(stage, 'blocks')
    data = subjects;
    blocks = allBlocks;
    return;
end

% --- Extract segments ---
doSetT0 = strcmp(stage, 'aligned');
preTime = 10;  % seconds before block onset (for baseline)

allSegments = {};
for s = 1:nSubjects
    segs = pf2.data.extractBlocks(subjects{s}, allBlocks{s}, ...
        'PreTime', preTime, ...
        'PostTime', 15, ...
        'SetT0', doSetT0, ...
        'CopyInfo', true);
    allSegments = [allSegments, segs]; %#ok<AGROW>
end

data = allSegments;
blocks = allBlocks;
end
