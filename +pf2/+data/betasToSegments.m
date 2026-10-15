function segments = betasToSegments(glmResults, data, varargin)
% BETASTOSEGMENTS Package GLM betas into Experiment-compatible pseudo-segments
%
% Converts first-level GLM beta weights into fNIRS-like structs that can be
% fed directly into exploreFNIRS.core.Experiment for group-level analysis.
% Each stimulus regressor becomes a separate pseudo-segment with the beta
% row as its "time series" (duplicated to 2 timepoints for compatibility
% with grandAvgFNIRS).
%
% Syntax:
%   segments = pf2.data.betasToSegments(glmResults, data)
%   segments = pf2.data.betasToSegments(glmResults, data, 'Name', Value)
%
% Inputs:
%   glmResults - Struct from pf2_base.fnirs.fitGLM with fields:
%                .beta [P x C], .regressorNames {1 x P}
%   data       - Original processed fNIRS struct (source of .info, .fchMask,
%                .units, and probe geometry)
%
% Name-Value Parameters:
%   'Biomarker'        - Which biomarker field to populate (default: 'HbO')
%   'Conditions'       - Cell array of regressor names to include
%                        (default: auto-detect stimulus regressors)
%   'ConditionMap'     - Cell {regName, 'Label'; ...} to rename conditions
%                        (default: {})
%   'Units'            - Units string for beta segments (default: '\beta')
%   'BiomarkerResults' - Struct with fields named by biomarker (e.g. .HbO,
%                        .HbR), each containing a fitGLM result. When
%                        provided, glmResults is ignored and each biomarker
%                        is populated from its own model. (default: [])
%
% Outputs:
%   segments - Cell array {1 x nConditions} of fNIRS-like structs with:
%              .HbO/.HbR/.HbTotal/.HbDiff/.CBSI - [1 x C] beta values
%              .time     - 0 (scalar, single timepoint)
%              .fs       - 1
%              .fchMask  - copied from data
%              .units    - '\beta'
%              .info     - copied from data with .Condition set
%              .markers  - empty [0 x 3]
%
% Algorithm:
%   1. Auto-detect stimulus regressors (exclude drift, constant, short-ch,
%      derivative, dispersion regressors)
%   2. For each stimulus regressor, extract beta row [1 x C]
%   3. Create single-timepoint pseudo-segment (time = 0)
%   4. Fill non-fitted biomarkers with NaN
%   5. Copy metadata from source data
%
% Example:
%   results = pf2_base.fnirs.fitGLM(data.HbO, X, names);
%   segments = pf2.data.betasToSegments(results, data);
%   ex = exploreFNIRS.core.Experiment(segments);
%   ex.settings.useBaseline = false;
%   ex.settings.resampleRate = 0;
%
% See also: pf2_base.fnirs.fitGLM, pf2.data.blocksToEvents,
%           exploreFNIRS.core.Experiment

% --- Parse inputs ---
% Inputs are parsed with pf2_base.args rather than an arguments block so
% the function also runs under GNU Octave. Spec rows are {name, default,
% size, class, validators}.
glmResults = pf2_base.args.check(glmResults, '', '', {@(v) mustBeA(v, 'struct')}, 'Invalid argument at position 1.');
data = pf2_base.args.check(data, '', '', {@(v) mustBeA(v, 'struct')}, 'Invalid argument at position 2.');
opts = pf2_base.args.parse('betasToSegments', varargin, {}, {
    'Biomarker',        ('HbO'), '', '', {}
    'Conditions',       ({}), '', '', {@(v) mustBeA(v, 'cell')}
    'ConditionMap',     ({}), '', '', {@(v) mustBeA(v, 'cell')}
    'Units',            ('\beta'), '', '', {}
    'BiomarkerResults', ([]), '', '', {}
    });

biomarker = char(opts.Biomarker);
conditions = opts.Conditions;
conditionMap = opts.ConditionMap;
units = char(opts.Units);
bioResults = opts.BiomarkerResults;

% All biomarker fields
allBiomarkers = {'HbO', 'HbR', 'HbTotal', 'HbDiff', 'CBSI'};

% --- Determine which results to use ---
if ~isempty(bioResults)
    % Multi-biomarker mode
    fittedBios = intersect(fieldnames(bioResults), allBiomarkers, 'stable');
    if isempty(fittedBios)
        error('pf2:betasToSegments:noBiomarkers', ...
            'BiomarkerResults must have fields named HbO, HbR, etc.');
    end
    % Use first fitted biomarker for regressor names
    primaryResult = bioResults.(fittedBios{1});
else
    % Single-biomarker mode
    fittedBios = {biomarker};
    primaryResult = glmResults;
    bioResults = struct();
    bioResults.(biomarker) = glmResults;
end

regressorNames = primaryResult.regressorNames;
nCh = size(primaryResult.beta, 2);

% --- Determine stimulus conditions ---
if isempty(conditions)
    conditions = detectStimulusRegressors(regressorNames);
end

if isempty(conditions)
    error('pf2:betasToSegments:noConditions', ...
        'No stimulus regressors found. Available: %s', ...
        strjoin(regressorNames, ', '));
end

% --- Build condition map ---
mapNames = containers.Map();
if ~isempty(conditionMap) && size(conditionMap, 2) >= 2
    for k = 1:size(conditionMap, 1)
        mapNames(char(conditionMap{k, 1})) = char(conditionMap{k, 2});
    end
end

% --- Build pseudo-segments ---
nCond = length(conditions);
segments = cell(1, nCond);

for c = 1:nCond
    condName = char(conditions{c});

    % Find regressor index
    regIdx = find(strcmp(regressorNames, condName), 1);
    if isempty(regIdx)
        error('pf2:betasToSegments:regressorNotFound', ...
            'Regressor "%s" not found. Available: %s', ...
            condName, strjoin(regressorNames, ', '));
    end

    % Determine display label
    if mapNames.isKey(condName)
        label = mapNames(condName);
    else
        label = condName;
    end

    % Build pseudo-segment
    seg = struct();

    % Fill each biomarker (single timepoint — betas are scalar per channel)
    for b = 1:length(allBiomarkers)
        bio = allBiomarkers{b};
        if isfield(bioResults, bio)
            seg.(bio) = bioResults.(bio).beta(regIdx, :);  % [1 x C]
        else
            seg.(bio) = NaN(1, nCh);
        end
    end

    % Single timepoint — betas have no temporal dimension
    seg.time = 0;
    seg.fs = 1;

    % Channel mask
    if isfield(data, 'fchMask')
        seg.fchMask = data.fchMask;
    else
        seg.fchMask = ones(1, nCh);
    end

    % Units
    seg.units = units;

    % Markers (empty canonical table)
    seg.markers = pf2_base.normalizeMarkers([]);

    % Info - copy from source data, set Condition
    if isfield(data, 'info')
        seg.info = data.info;
    else
        seg.info = struct();
    end
    seg.info.Condition = label;

    % Copy probe geometry if present
    if isfield(data, 'probe')
        seg.probe = data.probe;
    end

    % Copy ROI if present
    if isfield(data, 'ROI')
        seg.ROI = data.ROI;
    end

    segments{c} = seg;
end

end


function stimRegs = detectStimulusRegressors(regressorNames)
% DETECTSTIMULUSREGRESSORS Identify stimulus regressors by excluding nuisance
%
% Nuisance patterns: constant, drift_*, dct_*, short_ch*, nuis*, aux_*,
% *_deriv, *_disp

nuisancePatterns = {
    '^constant$'
    '^drift_'
    '^dct_'
    '^short_ch'
    '^nuis\d'
    '^aux_'
    '_deriv$'
    '_disp$'
};

isNuisance = false(size(regressorNames));
for k = 1:length(nuisancePatterns)
    isNuisance = isNuisance | ~cellfun(@isempty, regexp(regressorNames, nuisancePatterns{k}));
end

stimRegs = regressorNames(~isNuisance);

end
