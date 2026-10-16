classdef Experiment < handle
% EXPERIMENT Scriptable container for multi-subject fNIRS group analysis
%
% The Experiment class provides a CLI-friendly interface to exploreFNIRS
% group analysis operations. It wraps data organization, filtering,
% grouping, hierarchical averaging, and export into a chainable API
% that doesn't require the GUI.
%
% Syntax:
%   ex = exploreFNIRS.core.Experiment(data)
%   ex = exploreFNIRS.core.Experiment(data, 'Hierarchy', {'SubjectID','Session'})
%   ex2 = exploreFNIRS.core.Experiment(ex)   % copy data, settings, hierarchy
%
% Inputs:
%   data      - Cell array of processed fNIRS structs (from processFNIRS2),
%               or another Experiment object (copies data, settings, hierarchy)
%
% Name-Value Parameters:
%   Hierarchy - Cell array of hierarchy level names (default:
%               {'SubjectID','Session','Condition','Trial','Block'})
%               Column 1 = highest level (Subject), last = lowest (Trial).
%               Used for within-subject averaging to prevent pseudoreplication.
%
% Example:
%   % Load processed data
%   files = dir('processed/*.mat');
%   data = cell(length(files), 1);
%   for i = 1:length(files)
%       tmp = load(fullfile(files(i).folder, files(i).name));
%       data{i} = tmp.processed;
%   end
%
%   % Create experiment and run analysis
%   ex = exploreFNIRS.core.Experiment(data);
%   ex.select('Group', 'Control', 'Condition', {'Natural','Synthetic'});
%   ex.groupby({'Group', 'Condition'});
%   ex.aggregate();
%
%   % View results
%   ex.summary();
%
%   % Export
%   T = ex.toLongTable({'HbO','HbR'});
%   writetable(T, 'results.csv');
%
% See also: exploreFNIRS, processFNIRS2, grandAvgFNIRS

    properties
        % Cell array of processed fNIRS structs (immutable source data)
        data

        % Metadata table built from data.info fields
        dataTable

        % Hierarchy levels for within-subject averaging
        % Default: {'SubjectID','Session','Condition','Trial','Block'}
        hierarchy

        % Analysis settings
        settings

        % Hierarchical color scheme for plots (optional)
        % See also: exploreFNIRS.core.ColorScheme
        colorScheme

        % Named color scheme presets (struct of ColorScheme objects)
        % Use addColorScheme/useColorScheme to manage.
        % See also: exploreFNIRS.core.ColorScheme
        colorSchemes
    end

    properties (SetAccess = private)
        % Logical index into data for current selection
        selectedIdx

        % Variable names used for current grouping
        groupByVars

        % Struct array of grouped data (matches ExFNIRS.gby format)
        groups

        % State flags
        isGrouped
        isAggregated

        % Transient state snapshot (used by PlotProxy for save/restore)
        stateSnapshot

        % Preserved order from select() for each variable
        % struct with field names = variable names, values = ordered cell arrays
        selectOrder_

        % Per-segment preprocessing cache that survives reset()
        % Cell array same size as obj.data; each element is [] or
        % struct('pp', preprocessedSeg, 'bar', barSeg)
        ppCache_

        % ppKey string for which ppCache_ is valid
        ppCacheKey_
    end

    properties (Dependent, SetAccess = private)
        % PlotProxy for grammar-of-graphics style plotting
        plot
    end

    methods

        function obj = Experiment(data, varargin)
        % EXPERIMENT Create a new Experiment from processed fNIRS data
        %
        %   ex = Experiment(data)
        %   ex = Experiment(data, 'Hierarchy', {'SubjectID','Condition'})
        %   ex2 = Experiment(ex)   % copy data, settings, hierarchy

            % Copy from another Experiment (source hierarchy as default,
            % caller's varargin appended last so it takes priority)
            if isa(data, 'exploreFNIRS.core.Experiment')
                src = data;
                data = src.data;
                varargin = [{'Hierarchy', src.hierarchy}, varargin];
            end

            if ~iscell(data) || isempty(data)
                error('exploreFNIRS:core:Experiment', ...
                    'Input must be a non-empty cell array of fNIRS structs');
            end

            % Force column cell array
            obj.data = data(:);

            % Build metadata table
            obj.dataTable = exploreFNIRS.dataset.buildSegmentInfoTable(obj.data);

            % Add missingFNIRS column (required by export functions)
            % All data passed to Experiment is assumed valid
            obj.dataTable.missingFNIRS = zeros(height(obj.dataTable), 1);

            % Parse options
            p = inputParser;
            addParameter(p, 'Hierarchy', ...
                {'SubjectID','Session','Condition','Trial','Block'}, @iscell);
            parse(p, varargin{:});
            obj.hierarchy = p.Results.Hierarchy;

            % Default settings
            obj.settings = struct( ...
                'baseline',     [-5, 0], ...     % [start, end] seconds for baseline window
                'taskStart',    0, ...           % task onset time (for bin alignment)
                'taskEnd',      Inf, ...         % task end time (Inf = use full segment)
                'resampleRate', 0.5, ...         % seconds per bin for temporal (0 = no resample)
                'barBinSize',   0, ...           % seconds per bin for bar (0 = full task window, 1 bar)
                'useBaseline',  true, ...        % apply baseline correction
                'avgMode',      'hierarchy', ... % 'hierarchy', 'flat', or 'none'
                'rawMethod',    '', ...          % Raw processing method name ('' = no reprocessing)
                'oxyMethod',    '', ...          % Oxy processing method name ('' = no reprocessing)
                'statWindow',   [], ...          % [start, end] for bar/LME stats ([] = full range)
                'viewPad',      [5, 5], ...      % Plot-only padding (seconds) around the
                                ...              % baseline-start / task-end edges. Affects what
                                ...              % plotTemporal/plotHeatmap show only; bar values
                                ...              % stay pinned to [taskStart, taskEnd].
                                ...              % [] = strict trim to [taskStart, taskEnd]
                                ...              % scalar n = symmetric pad [n, n]
                                ...              % [pre, post] = asymmetric pad
                                ...              % Pre extends below baseline(1) (or taskStart if
                                ...              % useBaseline=false). Post extends above taskEnd
                                ...              % (or segment max if taskEnd=Inf).
                'timeModel',    '', ...          % TimeModel for LME: 'polynomial','discrete','continuous','none' ('' = fitLME default)
                'polyOrder',    2 ...            % Polynomial order for GCA (1-5, default: 2)
            );

            % Copy settings from source Experiment
            if exist('src', 'var')
                obj.settings = src.settings;
            end

            % Initialize color schemes
            obj.colorSchemes = struct();

            % Initialize state
            obj.selectedIdx = true(length(obj.data), 1);
            obj.groupByVars = {};
            obj.groups = [];
            obj.isGrouped = false;
            obj.isAggregated = false;
            obj.ppCache_ = cell(length(obj.data), 1);
            obj.ppCacheKey_ = '';
        end


        function proxy = get.plot(obj)
        % GET.PLOT Return a PlotProxy linked to this Experiment
        %
        %   fig = ex.plot.bar('X', 'Condition', 'Color', 'Group', 'Channels', 5)
        %   fig = ex.plot.temporal('Color', 'Group', 'Channels', 1:5)
        %
        % See also: exploreFNIRS.core.PlotProxy
            proxy = exploreFNIRS.core.PlotProxy(obj);
        end


        function obj = addColorScheme(obj, name, cs)
        % ADDCOLORSCHEME Register a named color scheme preset
        %
        %   ex.addColorScheme('byGroup', csGroup)
        %   ex.addColorScheme('byCondition', csCond)
        %
        % Stores the ColorScheme under the given name for later use with
        % useColorScheme() or per-plot 'ColorScheme' parameter.
        %
        % See also: useColorScheme, removeColorScheme, ColorScheme

            if ~isvarname(name)
                error('exploreFNIRS:core:Experiment:addColorScheme', ...
                    'Name "%s" is not a valid MATLAB identifier.', name);
            end
            if ~isa(cs, 'exploreFNIRS.core.ColorScheme')
                error('exploreFNIRS:core:Experiment:addColorScheme', ...
                    'Value must be an exploreFNIRS.core.ColorScheme object.');
            end
            obj.colorSchemes.(name) = cs;
        end


        function obj = removeColorScheme(obj, name)
        % REMOVECOLORSCHEME Remove a named color scheme preset
        %
        %   ex.removeColorScheme('byGroup')
        %
        % See also: addColorScheme, useColorScheme

            if ~isfield(obj.colorSchemes, name)
                error('exploreFNIRS:core:Experiment:removeColorScheme', ...
                    'Color scheme "%s" not found.', name);
            end
            obj.colorSchemes = rmfield(obj.colorSchemes, name);
        end


        function obj = useColorScheme(obj, name)
        % USECOLORSCHEME Set the active color scheme from a named preset
        %
        %   ex.useColorScheme('byGroup')
        %
        % Looks up the named preset and assigns it to ex.colorScheme.
        %
        % See also: addColorScheme, removeColorScheme

            if ~isfield(obj.colorSchemes, name)
                error('exploreFNIRS:core:Experiment:useColorScheme', ...
                    'Color scheme "%s" not found. Available: %s', ...
                    name, strjoin(fieldnames(obj.colorSchemes), ', '));
            end
            obj.colorScheme = obj.colorSchemes.(name);
        end


        function out = select(obj, varargin)
        % SELECT Filter data by metadata criteria
        %
        %   ex.select('VarName', value, ...)      % mutate in place
        %   ex2 = ex.select('VarName', value, ...) % return independent copy
        %
        % When an output is captured, select() returns a NEW Experiment
        % containing only the matching segments (the original is unchanged).
        % When called without capturing an output, it filters in place.
        %
        % Values can be:
        %   - String/char:   exact match (e.g., 'Group', 'Control')
        %   - Cell/string array: match any (e.g., 'Condition', {'A','B'})
        %   - Numeric scalar: exact match
        %   - Numeric vector: match any
        %
        % Calling select() again narrows the current selection (AND logic).
        % Use reset() first to start fresh.
        %
        % Example:
        %   ex.select('Group', 'Control');                  % in-place
        %   ex2 = ex.select('Condition', {'Task1','Task2'}); % new copy

            if mod(length(varargin), 2) ~= 0
                error('exploreFNIRS:core:Experiment:select', ...
                    'Arguments must be name-value pairs');
            end

            idx = obj.selectedIdx;

            selectOrder = struct();

            for i = 1:2:length(varargin)
                varName = varargin{i};
                varVal  = varargin{i+1};

                if ~ismember(varName, obj.dataTable.Properties.VariableNames)
                    error('exploreFNIRS:core:Experiment:select', ...
                        'Variable "%s" not found in dataTable. Available: %s', ...
                        varName, strjoin(obj.dataTable.Properties.VariableNames, ', '));
                end

                col = obj.dataTable.(varName);

                if ischar(varVal)
                    varVal = string(varVal);
                end

                if isstring(varVal) || iscell(varVal)
                    % String matching
                    varVal = string(varVal);
                    if isstring(col) || iscategorical(col) || iscell(col)
                        idx = idx & ismember(string(col), varVal);
                    else
                        idx = idx & ismember(col, varVal);
                    end
                    % Store the user-specified order for this variable
                    selectOrder.(varName) = cellstr(varVal);
                elseif isnumeric(varVal)
                    idx = idx & ismember(col, varVal);
                    if numel(varVal) > 1
                        selectOrder.(varName) = varVal;
                    end
                else
                    error('exploreFNIRS:core:Experiment:select', ...
                        'Unsupported value type for "%s"', varName);
                end
            end

            nSel = sum(idx);
            nTot = length(idx);

            if nargout > 0
                % Return a new independent Experiment with selected data
                out = exploreFNIRS.core.Experiment(obj.data(idx), ...
                    'Hierarchy', obj.hierarchy);
                out.settings = obj.settings;
                out.selectOrder_ = selectOrder;
                if ~isempty(obj.colorScheme)
                    out.colorScheme = obj.colorScheme;
                end
                out.colorSchemes = obj.colorSchemes;
                fprintf('Selected %d of %d segments (new Experiment)\n', nSel, nTot);
            else
                % Mutate in place
                obj.selectedIdx = idx;
                obj.isGrouped = false;
                obj.isAggregated = false;
                obj.groups = [];
                % Merge selectOrder into existing
                if isempty(obj.selectOrder_)
                    obj.selectOrder_ = selectOrder;
                else
                    fns = fieldnames(selectOrder);
                    for fi = 1:numel(fns)
                        obj.selectOrder_.(fns{fi}) = selectOrder.(fns{fi});
                    end
                end
                fprintf('Selected %d of %d segments\n', nSel, nTot);
            end
        end


        function obj = reset(obj)
        % RESET Clear selection and grouping, return to full dataset
        %
        %   ex.reset();

            obj.selectedIdx = true(length(obj.data), 1);
            obj.groupByVars = {};
            obj.groups = [];
            obj.isGrouped = false;
            obj.isAggregated = false;
        end


        function selData = getSelectedData(obj)
        % GETSELECTEDDATA Return cell array of currently selected fNIRS structs
            selData = obj.data(obj.selectedIdx);
        end


        function selTable = getSelectedTable(obj)
        % GETSELECTEDTABLE Return metadata table for current selection
            selTable = obj.dataTable(obj.selectedIdx, :);
        end


        function obj = groupby(obj, vars)
        % GROUPBY Group selected data by metadata variables
        %
        %   ex.groupby({'Group', 'Condition'})
        %   ex.groupby('Group')
        %
        % Creates groups based on unique combinations of the specified
        % variables. Must be called after select() (or on full dataset).
        % Must be called before aggregate().

            if ischar(vars) || isstring(vars)
                vars = cellstr(vars);
            end

            % Validate variable names exist
            selTable = obj.getSelectedTable();
            for i = 1:length(vars)
                if ~ismember(vars{i}, selTable.Properties.VariableNames)
                    error('exploreFNIRS:core:Experiment:groupby', ...
                        'Variable "%s" not found. Available: %s', ...
                        vars{i}, strjoin(selTable.Properties.VariableNames, ', '));
                end
            end

            obj.groupByVars = vars;
            selData = obj.getSelectedData();
            selIdx = find(obj.selectedIdx);  % original data indices

            [groupRows, ~, gbyIdx] = unique(selTable(:, vars), 'rows');
            nGroups = max(gbyIdx);

            % Reorder groups to match select() order when available
            if ~isempty(obj.selectOrder_) && length(vars) == 1 && ...
                    isfield(obj.selectOrder_, vars{1})
                desiredOrder = obj.selectOrder_.(vars{1});
                if iscell(desiredOrder)
                    currentOrder = cellstr(string(groupRows.(vars{1})));
                    [~, newIdx] = ismember(desiredOrder, currentOrder);
                    newIdx = newIdx(newIdx > 0);
                    % Append any groups not in the desired order
                    remaining = setdiff(1:nGroups, newIdx, 'stable');
                    newIdx = [newIdx, remaining];
                    if length(newIdx) == nGroups
                        % Remap gbyIdx to new order
                        invMap = zeros(1, nGroups);
                        invMap(newIdx) = 1:nGroups;
                        gbyIdx = invMap(gbyIdx)';
                        groupRows = groupRows(newIdx, :);
                    end
                end
            end

            obj.groups = [];
            for g = 1:nGroups
                mask = gbyIdx == g;
                obj.groups(g).gbyTables = selTable(mask, :);
                obj.groups(g).gbyFNIRS  = selData(mask);
                obj.groups(g).dataIdx   = selIdx(mask);  % original indices into obj.data
                obj.groups(g).gbyGrand  = [];
                obj.groups(g).gbyGrandBarFlat = [];
                obj.groups(g).gbyFNIRS_pp = {};
                obj.groups(g).cache = struct('ppData', {{}}, 'barData', {{}}, 'ppKey', '');

                % Build human-readable label
                rowVals = cell(1, length(vars));
                for v = 1:length(vars)
                    val = groupRows.(vars{v})(g);
                    if isnumeric(val)
                        rowVals{v} = num2str(val);
                    else
                        rowVals{v} = char(string(val));
                    end
                end
                obj.groups(g).label = strjoin(rowVals, ' | ');
            end

            obj.isGrouped = true;
            obj.isAggregated = false;

            fprintf('Created %d groups:\n', nGroups);
            for g = 1:nGroups
                fprintf('  [%d] %s  (%d segments)\n', ...
                    g, obj.groups(g).label, size(obj.groups(g).gbyTables, 1));
            end
        end


        function obj = aggregate(obj, mode)
        % AGGREGATE Preprocess segments and compute grand averages
        %
        %   ex.aggregate()              % Uses settings.avgMode (default: 'hierarchy')
        %   ex.aggregate('hierarchy')   % Full hierarchical averaging
        %   ex.aggregate('flat')        % Average within subject only
        %   ex.aggregate('none')        % No within-subject averaging
        %
        % Preprocessing (controlled by settings):
        %   If settings.resampleRate > 0, each segment is resampled to that
        %   bin size (in seconds). If settings.useBaseline is true, the
        %   baseline window (settings.baseline) is extracted and subtracted.
        %
        % Two grand averages are produced per group:
        %
        %   gbyGrand        - Temporal grand average. Time vector is widened
        %                     by settings.viewPad (default [5,5]) so that
        %                     plotTemporal/plotHeatmap can show samples
        %                     before baseline and after task end. Used by
        %                     plotTemporal, plotHeatmap, and the time-mask
        %                     in plotBar (see settings.statWindow).
        %
        %   gbyGrandBarFlat - Bar grand average. Time vector is strictly
        %                     [0, taskDuration) regardless of viewPad. Used
        %                     by toLongTable / toWideTable, writeCSV,
        %                     statsFitLME, plotScatter, and
        %                     plotNeuralEfficiency. Bar values stay pinned
        %                     to the task window even when viewPad widens
        %                     the temporal view.
        %
        % Averaging Modes:
        %   'hierarchy' - Averages bottom-up through hierarchy levels
        %                 (Trial -> Condition -> Session -> Subject)
        %                 Prevents pseudoreplication.
        %   'flat'      - Average all observations per subject (one value each)
        %   'none'      - Each observation treated independently

            if ~obj.isGrouped
                error('exploreFNIRS:core:Experiment:aggregate', ...
                    'Call groupby() before aggregate()');
            end

            % Clear prior aggregation results to allow safe re-aggregation
            for g = 1:length(obj.groups)
                obj.groups(g).gbyGrand = [];
                obj.groups(g).gbyGrandBarFlat = [];
                obj.groups(g).gbyFNIRS_pp = [];
            end
            obj.isAggregated = false;

            if nargin < 2
                mode = obj.settings.avgMode;
            end

            s = obj.settings;
            doResample = s.resampleRate > 0;
            doBaseline = s.useBaseline && ~isempty(s.baseline);

            % Find which hierarchy columns actually exist in the data
            availableVars = obj.dataTable.Properties.VariableNames;
            validHierarchy = intersect(obj.hierarchy, availableVars, 'stable');

            if doResample || doBaseline
                if isfinite(s.taskEnd)
                    fprintf('Preprocessing: resample=%.2fs, baseline=[%.1f, %.1f]s, task=[%.1f, %.1f]s', ...
                        s.resampleRate, s.baseline(1), s.baseline(2), s.taskStart, s.taskEnd);
                else
                    fprintf('Preprocessing: resample=%.2fs, baseline=[%.1f, %.1f]s, taskStart=%.1fs', ...
                        s.resampleRate, s.baseline(1), s.baseline(2), s.taskStart);
                end
                if ~isempty(s.viewPad)
                    pad = s.viewPad;
                    if isscalar(pad), pad = [pad, pad]; end
                    fprintf(', viewPad=[%.1f, %.1f]s', pad(1), pad(2));
                end
                fprintf('\n');
            end
            fprintf('Aggregating %d groups (mode: %s)...\n', length(obj.groups), mode);

            % --- Build reprocessing args if methods are specified ---
            hasMethodSet = ~isempty(s.rawMethod) || ~isempty(s.oxyMethod);
            reprocessArgs = {};
            if hasMethodSet
                if ~isempty(s.rawMethod) && ~isempty(s.oxyMethod)
                    reprocessArgs = {s.rawMethod, s.oxyMethod};
                elseif ~isempty(s.rawMethod)
                    reprocessArgs = {s.rawMethod};
                elseif ~isempty(s.oxyMethod)
                    % Only oxyMethod set: must pass both positional args
                    % to avoid oxyMethod being interpreted as rawMethod.
                    % Look up current rawMethod from the first segment.
                    curRaw = 'None';
                    firstData = obj.groups(1).gbyFNIRS;
                    if ~isempty(firstData) && isfield(firstData{1}, 'processingInfo') ...
                            && isfield(firstData{1}.processingInfo, 'rawMethod')
                        curRaw = firstData{1}.processingInfo.rawMethod;
                    end
                    reprocessArgs = {curRaw, s.oxyMethod};
                end
            end

            % --- Stage A: Reprocessing + Preprocessing (sequential) ---
            nGroups = length(obj.groups);
            ppKey = buildPPKey(s);
            allPPData   = cell(1, nGroups);
            allBarData  = cell(1, nGroups);
            allHVars    = cell(1, nGroups);
            allFlatH    = cell(1, nGroups);
            allBarBins  = nan(1, nGroups);
            skipGroup   = false(1, nGroups);

            % Invalidate per-segment cache if preprocessing settings changed
            if ~strcmp(ppKey, obj.ppCacheKey_)
                obj.ppCache_ = cell(length(obj.data), 1);
                obj.ppCacheKey_ = ppKey;
            end

            for g = 1:nGroups
                curData  = obj.groups(g).gbyFNIRS;
                curTable = obj.groups(g).gbyTables;
                dataIdx  = obj.groups(g).dataIdx;

                % Skip empty groups
                if isempty(curData)
                    warning('Group %d (%s) is empty, skipping', g, obj.groups(g).label);
                    skipGroup(g) = true;
                    continue;
                end

                % --- Reprocess only if methods changed since last aggregate ---
                if hasMethodSet
                    cachedRaw = '';
                    cachedOxy = '';
                    if isfield(obj.groups(g), 'cache') && ~isempty(obj.groups(g).cache)
                        if isfield(obj.groups(g).cache, 'rawMethod')
                            cachedRaw = obj.groups(g).cache.rawMethod;
                        end
                        if isfield(obj.groups(g).cache, 'oxyMethod')
                            cachedOxy = obj.groups(g).cache.oxyMethod;
                        end
                    end

                    methodChanged = ~strcmp(cachedRaw, s.rawMethod) || ...
                                    ~strcmp(cachedOxy, s.oxyMethod);

                    if methodChanged
                        curData = processFNIRS2(curData, reprocessArgs{:});
                        obj.groups(g).gbyFNIRS = curData;  % persist reprocessed data
                        obj.groups(g).cache.rawMethod = s.rawMethod;
                        obj.groups(g).cache.oxyMethod = s.oxyMethod;
                        % Invalidate per-segment cache for reprocessed segments
                        for ri = 1:length(dataIdx)
                            obj.ppCache_{dataIdx(ri)} = [];
                        end
                        fprintf('  [%d] %s: reprocessed %d segments (raw=%s, oxy=%s)\n', ...
                            g, obj.groups(g).label, length(curData), s.rawMethod, s.oxyMethod);
                    end
                end

                % --- Preprocessing (cached per-segment) ---
                allCached = all(~cellfun('isempty', obj.ppCache_(dataIdx)));

                if allCached
                    ppData  = cell(size(curData));
                    barData = cell(size(curData));
                    for i = 1:length(curData)
                        cached = obj.ppCache_{dataIdx(i)};
                        ppData{i}  = cached.pp;
                        barData{i} = cached.bar;
                    end
                    allPPData{g}  = ppData;
                    allBarData{g} = barData;
                    fprintf('  [%d] %s: using cached preprocessing (%d segments)\n', ...
                        g, obj.groups(g).label, length(curData));
                else
                    [allPPData{g}, allBarData{g}] = preprocessGroup(curData, s, doResample, doBaseline);
                    % Store in per-segment cache
                    for i = 1:length(curData)
                        obj.ppCache_{dataIdx(i)} = struct('pp', allPPData{g}{i}, 'bar', allBarData{g}{i});
                    end
                end

                % Build hierarchy args (cheap, needed for grandAvgFNIRS)
                allHVars{g}   = buildHierarchyVars(curTable, validHierarchy, mode);
                allFlatH{g}   = buildHierarchyVars(curTable, validHierarchy, 'flat');
                allBarBins(g) = computeBarBin(s, curData);
            end

            % --- Stage B: Grand averaging (parallel when pool available) ---
            activeIdx = find(~skipGroup);
            nActive = length(activeIdx);

            gaResults     = cell(1, nGroups);
            gaBarResults  = cell(1, nGroups);

            [canUse, poolRunning] = pf2_base.accel.canParfor();
            useParfor = canUse && poolRunning && nActive > 2;

            if useParfor
                % Extract loop variables for parfor compatibility
                ppCells  = allPPData(activeIdx);
                barCells = allBarData(activeIdx);
                hVCells  = allHVars(activeIdx);
                fhCells  = allFlatH(activeIdx);
                bbVec    = allBarBins(activeIdx);

                tmpGA    = cell(1, nActive);
                tmpBar   = cell(1, nActive);

                parfor k = 1:nActive
                    tmpGA{k}  = grandAvgFNIRS(ppCells{k}, false, [], false, hVCells{k}, false, true);
                    tmpBar{k} = grandAvgFNIRS(barCells{k}, false, bbVec(k), false, fhCells{k}, false, true);
                end

                for k = 1:nActive
                    gaResults{activeIdx(k)}    = tmpGA{k};
                    gaBarResults{activeIdx(k)} = tmpBar{k};
                end
            else
                for k = 1:nActive
                    g = activeIdx(k);
                    gaResults{g}    = grandAvgFNIRS(allPPData{g}, false, [], false, allHVars{g}, false, true);
                    gaBarResults{g} = grandAvgFNIRS(allBarData{g}, false, allBarBins(g), false, allFlatH{g}, false, true);
                end
            end

            % --- Write results back to obj ---
            for g = 1:nGroups
                if skipGroup(g), continue; end

                obj.groups(g).gbyGrand        = gaResults{g};
                obj.groups(g).gbyGrandBarFlat = gaBarResults{g};
                obj.groups(g).gbyFNIRS_pp     = allPPData{g};

                hasCachedPP = ~isempty(obj.groups(g).cache) && ...
                              isfield(obj.groups(g).cache, 'ppKey') && ...
                              strcmp(obj.groups(g).cache.ppKey, ppKey);

                % Persist the preprocessing cache on the group so that
                % subsequent aggregate() calls that only change the averaging
                % mode (not a preprocessing setting) can detect a cache hit.
                obj.groups(g).cache.ppKey  = ppKey;
                obj.groups(g).cache.ppData = allPPData{g};
                obj.groups(g).cache.barData = allBarData{g};

                if hasCachedPP
                    fprintf('  [%d] %s: re-averaged (%s mode)\n', ...
                        g, obj.groups(g).label, mode);
                else
                    fprintf('  [%d] %s: %d segments -> grand average\n', ...
                        g, obj.groups(g).label, length(obj.groups(g).gbyFNIRS));
                end
            end

            obj.isAggregated = true;
            fprintf('Done.\n');
        end


        function T = toLongTable(obj, bioMarkers, channels, times, varargin)
        % TOLONGTABLE Export grouped data to long format table
        %
        %   T = ex.toLongTable()
        %   T = ex.toLongTable({'HbO','HbR'})
        %   T = ex.toLongTable({'HbO'}, 1:10, [0 5 10])
        %   T = ex.toLongTable({'HbO'}, 1:5, [], 'IncludeAux', true)
        %   T = ex.toLongTable({'HbO'}, [], [], 'IncludeROI', true)
        %
        % Name-Value Parameters:
        %   IncludeAux - Include auxiliary data columns (default: false)
        %   IncludeROI - Include ROI-averaged data columns (default: false)
        %
        % See also: mergeGbyTablesLong

            if ~obj.isAggregated
                error('exploreFNIRS:core:Experiment:toLongTable', ...
                    'Call aggregate() before exporting');
            end
            if nargin < 2, bioMarkers = {'HbO','HbR','HbDiff','HbTotal','CBSI'}; end
            if nargin < 3, channels = []; end
            if nargin < 4, times = []; end

            ip = inputParser;
            addParameter(ip, 'IncludeAux', false, @islogical);
            addParameter(ip, 'IncludeROI', false, @islogical);
            parse(ip, varargin{:});

            % Build channel labels as cell array
            if ~isempty(channels)
                chLabels = pf2_base.channelLabels(channels);
            else
                chLabels = {};
            end

            T = exploreFNIRS.export.mergeGbyTablesLong( ...
                obj.groups, bioMarkers, channels, times, ...
                ip.Results.IncludeAux, ip.Results.IncludeROI, chLabels);
        end


        function T = toWideTable(obj, bioMarkers, channels, times, varargin)
        % TOWIDETABLE Export grouped data to wide format table
        %
        %   T = ex.toWideTable()
        %   T = ex.toWideTable({'HbO','HbR'})
        %   T = ex.toWideTable({'HbO'}, 1:10, [0 5 10])
        %   T = ex.toWideTable({'HbO'}, 1:5, [], 'IncludeAux', true)
        %   T = ex.toWideTable({'HbO'}, [], [], 'IncludeROI', true)
        %
        % Name-Value Parameters:
        %   IncludeAux - Include auxiliary data columns (default: false)
        %   IncludeROI - Include ROI-averaged data columns (default: false)
        %
        % See also: mergeGbyTablesWide

            if ~obj.isAggregated
                error('exploreFNIRS:core:Experiment:toWideTable', ...
                    'Call aggregate() before exporting');
            end
            if nargin < 2, bioMarkers = {'HbO','HbR','HbDiff','HbTotal','CBSI'}; end
            if nargin < 3, channels = []; end
            if nargin < 4, times = []; end

            ip = inputParser;
            addParameter(ip, 'IncludeAux', false, @islogical);
            addParameter(ip, 'IncludeROI', false, @islogical);
            parse(ip, varargin{:});

            % Build channel labels as cell array
            if ~isempty(channels)
                chLabels = pf2_base.channelLabels(channels);
            else
                chLabels = {};
            end

            T = exploreFNIRS.export.mergeGbyTablesWide( ...
                obj.groups, bioMarkers, channels, times, ...
                ip.Results.IncludeAux, ip.Results.IncludeROI, chLabels);
        end


        function T = writeCSV(obj, filepath, varargin)
        % WRITECSV Export aggregated data to a CSV file
        %
        %   ex.writeCSV('results.csv')
        %   ex.writeCSV('results.csv', 'Biomarkers', {'HbO','HbR'})
        %   ex.writeCSV('results.csv', 'Format', 'wide')
        %   T = ex.writeCSV('results.csv')   % also returns the table
        %
        % Name-Value Parameters:
        %   Format     - 'long' (default) or 'wide'
        %   Biomarkers - Cell array of biomarker names (default: all)
        %   Channels   - Channel indices (default: all)
        %   Times      - Time points (default: all)
        %   IncludeAux - Include auxiliary data (default: false)
        %   IncludeROI - Include ROI-averaged data (default: false)
        %
        % See also: toLongTable, toWideTable

            ip = inputParser;
            addRequired(ip, 'filepath', @ischar);
            addParameter(ip, 'Format', 'long', @ischar);
            addParameter(ip, 'Biomarkers', {'HbO','HbR','HbDiff','HbTotal','CBSI'}, @iscell);
            addParameter(ip, 'Channels', [], @isnumeric);
            addParameter(ip, 'Times', [], @isnumeric);
            addParameter(ip, 'IncludeAux', false, @islogical);
            addParameter(ip, 'IncludeROI', false, @islogical);
            parse(ip, filepath, varargin{:});
            opts = ip.Results;

            if strcmpi(opts.Format, 'wide')
                T = obj.toWideTable(opts.Biomarkers, opts.Channels, opts.Times, ...
                    'IncludeAux', opts.IncludeAux, 'IncludeROI', opts.IncludeROI);
            else
                T = obj.toLongTable(opts.Biomarkers, opts.Channels, opts.Times, ...
                    'IncludeAux', opts.IncludeAux, 'IncludeROI', opts.IncludeROI);
            end

            writetable(T, filepath);
            fprintf('Wrote %d rows x %d columns to %s\n', ...
                height(T), width(T), filepath);
        end


        function fig = plotExperimentTimeline(obj, varargin)
        % PLOTEXPERIMENTTIMELINE Visualize experiment time settings as a diagram
        %
        %   fig = ex.plotExperimentTimeline()
        %   fig = ex.plotExperimentTimeline('SavePath', 'timeline.png')
        %
        % Shows baseline, task block, temporal resample, and bar resample
        % settings. Does not require aggregate(). Useful for verifying
        % configuration before processing.
        %
        % See also: exploreFNIRS.core.plotExperimentTimeline

            % Infer data time range from first selected segment
            selData = obj.data(obj.selectedIdx);
            if ~isempty(selData)
                seg = selData{1};
                dataRange = [min(seg.time), max(seg.time)];
            else
                dataRange = [];
            end
            fig = exploreFNIRS.core.plotExperimentTimeline(obj.settings, ...
                'DataRange', dataRange, varargin{:});
        end


        function fig = plotTemporal(obj, varargin)
        % PLOTTEMPORAL Headless temporal (time-series) plot
        %
        %   fig = ex.plotTemporal()
        %   fig = ex.plotTemporal('Biomarkers', {'HbO'}, 'Channels', 1:5)
        %   ex.plotTemporal('SavePath', 'temporal.png')
        %
        % The visible time range is set at aggregate() time by
        % settings.viewPad (default [5,5] seconds, padding around
        % baseline-start and task-end). For visual cropping without
        % re-aggregating, pass 'XLim', [tmin tmax]. Bar values produced
        % by plotBar are auto-pinned to [taskStart, taskEnd] regardless
        % of viewPad — widening the view never changes a bar value.
        %
        % All name-value arguments are forwarded to
        % exploreFNIRS.core.plotTemporal. See help for that function.
        %
        % See also: exploreFNIRS.core.plotTemporal, plotHeatmap

            if ~obj.isAggregated
                error('exploreFNIRS:core:Experiment:plotTemporal', ...
                    'Call aggregate() before plotting');
            end
            varargin = obj.injectColorScheme(varargin);
            % Inject Device from data if not explicitly provided
            if ~any(strcmpi(varargin(1:2:end), 'Device'))
                dev = obj.resolveDevice();
                if ~isempty(dev)
                    varargin = [varargin, {'Device', dev}];
                end
            end
            fig = exploreFNIRS.core.plotTemporal(obj.groups, varargin{:});
        end


        function fig = plotBar(obj, varargin)
        % PLOTBAR Headless bar chart plot
        %
        %   fig = ex.plotBar()
        %   fig = ex.plotBar('Biomarker', 'HbO', 'Channels', 1:5)
        %   ex.plotBar('TimeWindow', [5, 20], 'SavePath', 'bar.png')
        %
        % All name-value arguments are forwarded to
        % exploreFNIRS.core.plotBar. See help for that function.
        %
        % See also: exploreFNIRS.core.plotBar

            if ~obj.isAggregated
                error('exploreFNIRS:core:Experiment:plotBar', ...
                    'Call aggregate() before plotting');
            end
            varargin = obj.injectColorScheme(varargin);
            varargin = obj.injectStatWindow(varargin);
            % Inject Device from data if not explicitly provided
            if ~any(strcmpi(varargin(1:2:end), 'Device'))
                dev = obj.resolveDevice();
                if ~isempty(dev)
                    varargin = [varargin, {'Device', dev}];
                end
            end
            fig = exploreFNIRS.core.plotBar(obj.groups, ...
                'GroupByVars', obj.groupByVars, varargin{:});
        end


        function fig = plotAux(obj, auxField, varargin)
        % PLOTAUX Plot auxiliary signal timeseries by group
        %
        %   fig = ex.plotAux('accelerometer')
        %   fig = ex.plotAux('heartRate', 'AuxChannels', 1)
        %   fig = ex.plotAux('accelerometer', 'Layout', 'grid', 'SavePath', 'accel.png')
        %
        % Plots multichannel auxiliary data (accelerometer, heart rate,
        % respiration, etc.) as time-series with error bands per group.
        % Requires aggregate() to have been called first.
        %
        % Use ex.auxFields() to see available Aux fields.
        %
        % See also: exploreFNIRS.core.plotAux, auxFields

            if ~obj.isAggregated
                error('exploreFNIRS:core:Experiment:plotAux', ...
                    'Call aggregate() before plotting');
            end
            varargin = obj.injectColorScheme(varargin);
            fig = exploreFNIRS.core.plotAux(obj.groups, auxField, varargin{:});
        end


        function fig = plotAuxBar(obj, auxField, varargin)
        % PLOTAUXBAR Bar chart for auxiliary signal data by group
        %
        %   fig = ex.plotAuxBar('heartRate')
        %   fig = ex.plotAuxBar('accelerometer', 'TimeWindow', [5, 20])
        %   fig = ex.plotAuxBar('heartRate', 'ShowIndividual', true, 'SavePath', 'hr.png')
        %
        % Plots mean auxiliary variable values per group as bar charts.
        % Each aux channel gets its own subplot. Requires aggregate() first.
        %
        % Use ex.auxFields() to see available Aux fields.
        %
        % See also: exploreFNIRS.core.plotAuxBar, plotAux, auxFields

            if ~obj.isAggregated
                error('exploreFNIRS:core:Experiment:plotAuxBar', ...
                    'Call aggregate() before plotting');
            end
            varargin = obj.injectColorScheme(varargin);
            fig = exploreFNIRS.core.plotAuxBar(obj.groups, auxField, ...
                'GroupByVars', obj.groupByVars, varargin{:});
        end


        function [fig, stats] = plotAuxScatter(obj, auxField, infoVar, varargin)
        % PLOTAUXSCATTER Scatter plot correlating info variable vs auxiliary data
        %
        %   [fig, stats] = ex.plotAuxScatter('heartRate', 'Age')
        %   [fig, stats] = ex.plotAuxScatter('heartRate', 'reactionTime', ...
        %       'AuxChannels', 1, 'FitLine', true)
        %
        % Correlates an info/behavioral variable (X) with auxiliary signal
        % channel data (Y). Requires aggregate() first.
        %
        % See also: exploreFNIRS.core.plotAuxScatter, plotAuxBar, auxFields

            if ~obj.isAggregated
                error('exploreFNIRS:core:Experiment:plotAuxScatter', ...
                    'Call aggregate() before plotAuxScatter()');
            end
            varargin = obj.injectColorScheme(varargin);
            [fig, stats] = exploreFNIRS.core.plotAuxScatter(obj.groups, ...
                auxField, 'InfoVar', infoVar, varargin{:});
        end


        function flds = auxFields(obj)
        % AUXFIELDS List available auxiliary data fields after aggregation
        %
        %   flds = ex.auxFields()
        %
        % Returns a cell array of Aux field names from the first group's
        % grand average. These names can be passed to plotAux().

            if ~obj.isAggregated || isempty(obj.groups)
                flds = {};
                fprintf('No aggregated data. Call aggregate() first.\n');
                return;
            end

            ga = obj.groups(1).gbyGrand;
            if ~isfield(ga, 'Aux') || ~isstruct(ga.Aux)
                flds = {};
                fprintf('No Aux data in aggregated results.\n');
                return;
            end

            % Get clean field names (handles flattened _data/_time/_unit suffixes)
            allFlds = fieldnames(ga.Aux);
            allFlds = allFlds(~ismember(allFlds, {'flattened'}));

            % Deduplicate: strip _data/_time/_unit, keep only fields with .Mean
            baseNames = {};
            for i = 1:length(allFlds)
                f = allFlds{i};
                base = regexprep(f, '_(data|time|unit)$', '');
                if ~ismember(base, baseNames)
                    % Check if this or _data version has .Mean
                    resolved = f;
                    if isfield(ga.Aux, [base '_data'])
                        resolved = [base '_data'];
                    end
                    if isstruct(ga.Aux.(resolved)) && isfield(ga.Aux.(resolved), 'Mean')
                        baseNames{end+1} = base; %#ok<AGROW>
                    end
                end
            end
            flds = unique(baseNames, 'stable');

            if nargout == 0
                % Print to console
                fprintf('Available Aux fields:\n');
                for i = 1:length(flds)
                    % Resolve to actual field name
                    if isfield(ga.Aux, flds{i})
                        actualField = flds{i};
                    elseif isfield(ga.Aux, [flds{i} '_data'])
                        actualField = [flds{i} '_data'];
                    else
                        continue;
                    end
                    auxData = ga.Aux.(actualField);
                    if isfield(auxData, 'Mean')
                        nCh = size(auxData.Mean, 2);
                        unitStr = '';
                        if isfield(auxData, 'unit')
                            unitStr = sprintf(' (%s)', auxData.unit);
                        end
                        nameStr = '';
                        if isfield(auxData, 'varNames') && ~isempty(auxData.varNames)
                            nameStr = sprintf(' [%s]', strjoin(auxData.varNames, ', '));
                        end
                        fprintf('  %s: %d channels%s%s\n', flds{i}, nCh, unitStr, nameStr);
                    else
                        fprintf('  %s\n', flds{i});
                    end
                end
                clear flds;
            end
        end


        function fig = plotInfoBar(obj, varName, varargin)
        % PLOTINFOBAR Plot a numeric info variable grouped by current groupby
        %
        %   fig = ex.plotInfoBar('reactionTime')
        %   fig = ex.plotInfoBar('accuracy', 'ErrorType', 'SD')
        %   fig = ex.plotInfoBar('Age', 'SavePath', 'age_by_group.png')
        %
        % Plots a bar chart of any numeric variable from the metadata table,
        % grouped by the current groupby variables. Does NOT require
        % aggregate() - works directly from the dataTable.
        %
        % Requires groupby() to have been called first.
        %
        % Name-Value Parameters:
        %   Averaging      - 'hierarchy' (default), 'flat', or 'none'
        %                    'hierarchy' averages within SubjectID first
        %                    'flat' uses raw values directly
        %                    'none' same as flat (raw block-level data)
        %   ErrorType      - 'SEM' (default), 'SD', or 'none'
        %   ShowIndividual - Show individual data points (default: true)
        %   Title          - Figure title (default: auto)
        %   YLabel         - Y-axis label (default: varName)
        %   Visible        - 'on' (default) or 'off'
        %   SavePath       - File path to save figure
        %   SaveWidth      - Width in pixels (default: 600)
        %   SaveHeight     - Height in pixels (default: 400)
        %   SaveDPI        - Resolution (default: 150)
        %
        % See also: plotBar, plotTemporal

            if ~obj.isGrouped
                error('exploreFNIRS:core:Experiment:plotInfoBar', ...
                    'Call groupby() before plotInfoBar()');
            end

            p = inputParser;
            addRequired(p, 'varName', @ischar);
            addParameter(p, 'Averaging', 'hierarchy', @(x) ismember(lower(x), {'hierarchy','flat','none'}));
            addParameter(p, 'ErrorType', 'SEM', @ischar);
            addParameter(p, 'ShowIndividual', true, @islogical);
            addParameter(p, 'Title', '', @ischar);
            addParameter(p, 'YLabel', '', @ischar);
            addParameter(p, 'Visible', 'on', @ischar);
            addParameter(p, 'SavePath', '', @ischar);
            addParameter(p, 'SaveWidth', 600, @isnumeric);
            addParameter(p, 'SaveHeight', 400, @isnumeric);
            addParameter(p, 'SaveDPI', 150, @isnumeric);
            addParameter(p, 'TightLayout', false, @islogical);
            addParameter(p, 'Colors', [], @(x) isempty(x) || isnumeric(x) || ischar(x) || isstring(x) || isa(x, 'function_handle') || isa(x, 'exploreFNIRS.core.ColorScheme'));
            addParameter(p, 'ColorScheme', [], @(x) isempty(x) || ischar(x) || isstring(x) || isa(x, 'exploreFNIRS.core.ColorScheme'));
            parse(p, varName, varargin{:});
            opts = p.Results;

            % Resolve named ColorScheme
            if ~isempty(opts.ColorScheme)
                csVal = opts.ColorScheme;
                if ischar(csVal) || isstring(csVal)
                    name = char(csVal);
                    if ~isfield(obj.colorSchemes, name)
                        error('exploreFNIRS:core:Experiment:plotInfoBar', ...
                            'Unknown color scheme: "%s". Available: %s', ...
                            name, strjoin(fieldnames(obj.colorSchemes), ', '));
                    end
                    csVal = obj.colorSchemes.(name);
                end
                if isempty(opts.Colors)
                    opts.Colors = csVal;
                end
            end

            % Auto-inject colorScheme if not explicitly set
            if isempty(opts.Colors) && ~isempty(obj.colorScheme)
                opts.Colors = obj.colorScheme;
            end

            if ~isempty(opts.SavePath)
                opts.Visible = 'off';
            end

            % Validate variable exists and is numeric
            selTable = obj.getSelectedTable();
            if ~ismember(varName, selTable.Properties.VariableNames)
                error('exploreFNIRS:core:Experiment:plotInfoBar', ...
                    'Variable "%s" not found. Available: %s', ...
                    varName, strjoin(selTable.Properties.VariableNames, ', '));
            end

            testCol = selTable.(varName);
            if ~isnumeric(testCol)
                error('exploreFNIRS:core:Experiment:plotInfoBar', ...
                    'Variable "%s" must be numeric (got %s)', varName, class(testCol));
            end

            nGroups = length(obj.groups);
            groupMeans = nan(1, nGroups);
            groupErrors = nan(1, nGroups);
            groupN = nan(1, nGroups);
            groupLabels = cell(1, nGroups);
            individualData = cell(1, nGroups);

            for g = 1:nGroups
                gTable = obj.groups(g).gbyTables;
                vals = gTable.(varName);
                if strcmpi(opts.Averaging, 'hierarchy') && ...
                        ismember('SubjectID', gTable.Properties.VariableNames)
                    vals = pf2_base.hierarchicalAverage(vals, ...
                        gTable(:, 'SubjectID'), @nanmean);
                end
                vals = vals(~isnan(vals));
                individualData{g} = vals;
                groupN(g) = length(vals);
                groupMeans(g) = mean(vals, 'omitnan');
                groupLabels{g} = obj.groups(g).label;

                switch upper(opts.ErrorType)
                    case 'SEM'
                        groupErrors(g) = std(vals, 'omitnan') / sqrt(groupN(g));
                    case 'SD'
                        groupErrors(g) = std(vals, 'omitnan');
                    case 'NONE'
                        groupErrors(g) = 0;
                end
            end

            % Colors
            if isa(opts.Colors, 'exploreFNIRS.core.ColorScheme')
                colors = opts.Colors.resolve(obj.groups);
            else
                colors = exploreFNIRS.core.getGroupColors(nGroups, opts.Colors);
            end

            fig = pf2_base.plot.createFigure('Visible', opts.Visible, ...
                'Width', opts.SaveWidth, 'Height', opts.SaveHeight, ...
                'SavePath', opts.SavePath);
            sty = pf2_base.plot.PlotStyle.getDefault();
            ax = axes('Parent', fig);
            hold(ax, 'on');

            % Build barweb inputs
            meanMatrix = groupMeans(:);   % [nGroups x 1]
            if strcmpi(opts.ErrorType, 'none')
                errInput = [];
            else
                errInput = groupErrors(:);
            end

            if ~isempty(opts.YLabel)
                ylabelStr = opts.YLabel;
            else
                ylabelStr = varName;
            end

            barwebArgs = {'Axes', ax, ...
                'ColorMap', colors(1,:), ...
                'YLabel', ylabelStr};

            if opts.ShowIndividual
                indivData = cell(nGroups, 1);
                for g = 1:nGroups
                    indivData{g, 1} = individualData{g};
                end
                barwebArgs = [barwebArgs, {'DataPoints', indivData}];
            end

            bwHandles = pf2_base.external.barweb(meanMatrix, errInput, ...
                0.8, groupLabels, barwebArgs{:}, 'ErrorColor', sty.ForegroundColor);
            hold(ax, 'on');

            % Color each bar individually
            if ~isempty(bwHandles.bars)
                bwHandles.bars(1).FaceColor = 'flat';
                bwHandles.bars(1).CData = colors(1:nGroups, :);
            end

            % Add x-axis margin so bars don't touch the edges
            xlim(ax, [0.25, nGroups + 0.75]);

            % Legend identifies bars — replace tick labels with xlabel
            set(ax, 'XTickLabel', {});
            xlabel(ax, pf2_base.plot.escapeTeX(strjoin(obj.groupByVars, ' x ')));

            % Legend with colored patches
            lh = gobjects(nGroups, 1);
            for g = 1:nGroups
                lh(g) = patch(ax, NaN, NaN, colors(g,:), ...
                    'EdgeColor', 'k', 'LineWidth', 2);
            end
            lg = legend(ax, lh, pf2_base.plot.escapeTeX(groupLabels), 'Location', 'best');
            lg.TextColor = sty.LegendTextColor;
            lg.Color = sty.LegendBgColor;
            lg.EdgeColor = sty.LegendEdgeColor;

            % N labels
            for g = 1:nGroups
                if ~isnan(groupN(g))
                    yPos = groupMeans(g) + groupErrors(g);
                    if isnan(yPos), yPos = groupMeans(g); end
                    text(ax, g, yPos, sprintf('n=%d', groupN(g)), ...
                        'HorizontalAlignment', 'center', ...
                        'VerticalAlignment', 'bottom', 'FontSize', 8);
                end
            end

            if ~isempty(opts.Title)
                title(ax, pf2_base.plot.escapeTeX(opts.Title));
            else
                title(ax, pf2_base.plot.escapeTeX(sprintf('%s by %s', varName, strjoin(obj.groupByVars, ', '))));
            end

            box(ax, 'on');
            grid(ax, 'on');

            sty.applyToFigure(fig);
            pf2_base.plot.handleSave(fig, opts);
        end


        function fig = plotInfoScatter(obj, xVar, yVar, varargin)
        % PLOTINFOSCATTER Scatter plot of two info variables, colored by group
        %
        %   fig = ex.plotInfoScatter('Age', 'reactionTime')
        %   fig = ex.plotInfoScatter('taskLoad', 'accuracy', 'FitLine', true)
        %
        % Plots xVar vs yVar from the metadata table. If groupby() has been
        % called, points are colored by group. Does NOT require aggregate().
        %
        % Name-Value Parameters:
        %   Averaging  - 'hierarchy' (default), 'flat', or 'none'
        %                'hierarchy' averages within SubjectID first
        %                'flat' uses raw values directly
        %                'none' same as flat (raw block-level data)
        %   FitLine    - Add linear fit per group (default: false)
        %   Title      - Figure title (default: auto)
        %   XLabel     - X-axis label (default: xVar)
        %   YLabel     - Y-axis label (default: yVar)
        %   MarkerSize - Point size (default: 40)
        %   Visible    - 'on' (default) or 'off'
        %   SavePath   - File path to save figure
        %   SaveWidth  - Width in pixels (default: 600)
        %   SaveHeight - Height in pixels (default: 400)
        %   SaveDPI    - Resolution (default: 150)
        %
        % See also: plotInfoBar, plotBar

            p = inputParser;
            addRequired(p, 'xVar', @ischar);
            addRequired(p, 'yVar', @ischar);
            addParameter(p, 'Averaging', 'hierarchy', @(x) ismember(lower(x), {'hierarchy','flat','none'}));
            addParameter(p, 'FitLine', false, @islogical);
            addParameter(p, 'ErrorBand', false, @islogical);
            addParameter(p, 'Title', '', @ischar);
            addParameter(p, 'XLabel', '', @ischar);
            addParameter(p, 'YLabel', '', @ischar);
            addParameter(p, 'MarkerSize', 40, @isnumeric);
            addParameter(p, 'Visible', 'on', @ischar);
            addParameter(p, 'SavePath', '', @ischar);
            addParameter(p, 'SaveWidth', 600, @isnumeric);
            addParameter(p, 'SaveHeight', 400, @isnumeric);
            addParameter(p, 'SaveDPI', 150, @isnumeric);
            addParameter(p, 'TightLayout', false, @islogical);
            addParameter(p, 'Colors', [], @(x) isempty(x) || isnumeric(x) || ischar(x) || isstring(x) || isa(x, 'function_handle') || isa(x, 'exploreFNIRS.core.ColorScheme'));
            addParameter(p, 'ColorScheme', [], @(x) isempty(x) || ischar(x) || isstring(x) || isa(x, 'exploreFNIRS.core.ColorScheme'));
            parse(p, xVar, yVar, varargin{:});
            opts = p.Results;

            % Resolve named ColorScheme
            if ~isempty(opts.ColorScheme)
                csVal = opts.ColorScheme;
                if ischar(csVal) || isstring(csVal)
                    name = char(csVal);
                    if ~isfield(obj.colorSchemes, name)
                        error('exploreFNIRS:core:Experiment:plotInfoScatter', ...
                            'Unknown color scheme: "%s". Available: %s', ...
                            name, strjoin(fieldnames(obj.colorSchemes), ', '));
                    end
                    csVal = obj.colorSchemes.(name);
                end
                if isempty(opts.Colors)
                    opts.Colors = csVal;
                end
            end

            % Auto-inject colorScheme if not explicitly set
            if isempty(opts.Colors) && ~isempty(obj.colorScheme)
                opts.Colors = obj.colorScheme;
            end

            if ~isempty(opts.SavePath)
                opts.Visible = 'off';
            end

            selTable = obj.getSelectedTable();

            % Validate variables
            for v = {xVar, yVar}
                vn = v{1};
                if ~ismember(vn, selTable.Properties.VariableNames)
                    error('exploreFNIRS:core:Experiment:plotInfoScatter', ...
                        'Variable "%s" not found. Available: %s', ...
                        vn, strjoin(selTable.Properties.VariableNames, ', '));
                end
                if ~isnumeric(selTable.(vn))
                    error('exploreFNIRS:core:Experiment:plotInfoScatter', ...
                        'Variable "%s" must be numeric (got %s)', vn, class(selTable.(vn)));
                end
            end

            xData = selTable.(xVar);
            yData = selTable.(yVar);

            fig = pf2_base.plot.createFigure('Visible', opts.Visible, ...
                'Width', opts.SaveWidth, 'Height', opts.SaveHeight, ...
                'SavePath', opts.SavePath);
            sty = pf2_base.plot.PlotStyle.getDefault();
            ax = axes('Parent', fig);
            hold(ax, 'on');

            if obj.isGrouped && ~isempty(obj.groups)
                nGroups = length(obj.groups);
                if isa(opts.Colors, 'exploreFNIRS.core.ColorScheme')
                    colors = opts.Colors.resolve(obj.groups);
                else
                    colors = exploreFNIRS.core.getGroupColors(nGroups, opts.Colors);
                end

                legendHandles = gobjects(nGroups, 1);
                legendLabels = cell(nGroups, 1);

                for g = 1:nGroups
                    gTable = obj.groups(g).gbyTables;
                    gx = gTable.(xVar);
                    gy = gTable.(yVar);

                    % Apply averaging
                    if strcmpi(opts.Averaging, 'hierarchy') && ...
                            ismember('SubjectID', gTable.Properties.VariableNames)
                        gx = pf2_base.hierarchicalAverage(gx, ...
                            gTable(:, 'SubjectID'), @nanmean);
                        gy = pf2_base.hierarchicalAverage(gy, ...
                            gTable(:, 'SubjectID'), @nanmean);
                    end

                    valid = ~isnan(gx) & ~isnan(gy);
                    gx = gx(valid);
                    gy = gy(valid);

                    legendHandles(g) = scatter(ax, gx, gy, opts.MarkerSize, ...
                        colors(g,:), 'filled', 'MarkerFaceAlpha', 0.7);
                    legendLabels{g} = sprintf('%s (n=%d)', obj.groups(g).label, sum(valid));

                    if opts.FitLine && sum(valid) >= 2
                        coeffs = polyfit(gx, gy, 1);
                        xFit = linspace(min(gx), max(gx), 50);
                        yFit = polyval(coeffs, xFit);
                        plot(ax, xFit, yFit, '-', 'Color', colors(g,:), ...
                            'LineWidth', 1.5, 'HandleVisibility', 'off');

                        if opts.ErrorBand && sum(valid) >= 3
                            yResid = gy - polyval(coeffs, gx);
                            se = std(yResid) * sqrt(1/sum(valid) + ...
                                (xFit - mean(gx)).^2 / sum((gx - mean(gx)).^2));
                            fill(ax, [xFit, fliplr(xFit)], ...
                                [yFit + 1.96*se, fliplr(yFit - 1.96*se)], ...
                                colors(g,:), 'FaceAlpha', 0.15, 'EdgeColor', 'none', ...
                                'HandleVisibility', 'off');
                        end
                    end
                end

                legend(ax, legendHandles, legendLabels, 'Location', 'best');
            else
                % No grouping - single color
                if isa(opts.Colors, 'exploreFNIRS.core.ColorScheme')
                    singleColor = exploreFNIRS.core.getGroupColors(1);
                else
                    singleColor = exploreFNIRS.core.getGroupColors(1, opts.Colors);
                end
                % Apply averaging
                xPlot = xData;
                yPlot = yData;
                if strcmpi(opts.Averaging, 'hierarchy') && ...
                        ismember('SubjectID', selTable.Properties.VariableNames)
                    xPlot = pf2_base.hierarchicalAverage(xData, ...
                        selTable(:, 'SubjectID'), @nanmean);
                    yPlot = pf2_base.hierarchicalAverage(yData, ...
                        selTable(:, 'SubjectID'), @nanmean);
                end

                valid = ~isnan(xPlot) & ~isnan(yPlot);
                scatter(ax, xPlot(valid), yPlot(valid), opts.MarkerSize, ...
                    singleColor, 'filled', 'MarkerFaceAlpha', 0.7);

                if opts.FitLine && sum(valid) >= 2
                    xv = xPlot(valid);
                    yv = yPlot(valid);
                    coeffs = polyfit(xv, yv, 1);
                    xFit = linspace(min(xv), max(xv), 50);
                    yFit = polyval(coeffs, xFit);
                    plot(ax, xFit, yFit, '-', 'Color', singleColor, ...
                        'LineWidth', 1.5, 'HandleVisibility', 'off');

                    if opts.ErrorBand && sum(valid) >= 3
                        yResid = yv - polyval(coeffs, xv);
                        se = std(yResid) * sqrt(1/sum(valid) + ...
                            (xFit - mean(xv)).^2 / sum((xv - mean(xv)).^2));
                        fill(ax, [xFit, fliplr(xFit)], ...
                            [yFit + 1.96*se, fliplr(yFit - 1.96*se)], ...
                            singleColor, 'FaceAlpha', 0.15, 'EdgeColor', 'none', ...
                            'HandleVisibility', 'off');
                    end
                end
            end

            if ~isempty(opts.XLabel), xlabel(ax, pf2_base.plot.escapeTeX(opts.XLabel));
            else, xlabel(ax, pf2_base.plot.escapeTeX(xVar)); end
            if ~isempty(opts.YLabel), ylabel(ax, pf2_base.plot.escapeTeX(opts.YLabel));
            else, ylabel(ax, pf2_base.plot.escapeTeX(yVar)); end

            if ~isempty(opts.Title)
                title(ax, pf2_base.plot.escapeTeX(opts.Title));
            else
                title(ax, pf2_base.plot.escapeTeX(sprintf('%s vs %s', yVar, xVar)));
            end

            box(ax, 'on');
            grid(ax, 'on');

            sty.applyToFigure(fig);
            pf2_base.plot.handleSave(fig, opts);
        end


        function [fig, stats] = plotScatter(obj, infoVar, varargin)
        % PLOTSCATTER Scatter plot correlating info variable vs fNIRS biomarker
        %
        %   [fig, stats] = ex.plotScatter('reactionTime')
        %   [fig, stats] = ex.plotScatter('Age', 'Biomarkers', {'HbO'}, ...
        %       'Channels', 5, 'FitLine', true)
        %   [fig, stats] = ex.plotScatter('Age', 'PlotTopo', true)
        %
        % Correlates an info/behavioral variable (X) with fNIRS biomarker
        % channel data (Y). Requires aggregate() first.
        %
        % See also: exploreFNIRS.core.plotScatter

            if ~obj.isAggregated
                error('exploreFNIRS:core:Experiment:plotScatter', ...
                    'Call aggregate() before plotScatter()');
            end
            varargin = obj.injectColorScheme(varargin);
            % Inject Device from data if not explicitly provided
            if ~any(strcmpi(varargin(1:2:end), 'Device'))
                dev = obj.resolveDevice();
                if ~isempty(dev)
                    varargin = [varargin, {'Device', dev}];
                end
            end
            [fig, stats] = exploreFNIRS.core.plotScatter(obj.groups, ...
                'InfoVar', infoVar, varargin{:});
        end


        function [fig, stats, neTable] = plotNeuralEfficiency(obj, infoVar, varargin)
        % PLOTNEURALEFFICIENCY Neural efficiency scatter plot
        %
        %   [fig, stats] = ex.plotNeuralEfficiency('accuracy')
        %   [fig, stats, neTable] = ex.plotNeuralEfficiency('RT', ...
        %       'Channels', 1:5, 'FitLine', true)
        %   [fig, stats] = ex.plotNeuralEfficiency('accuracy', ...
        %       'ZScoreMode', 'pergroup')
        %
        % Activation (X) vs performance (Y), z-scored. Identity line
        % separates efficient (above) from inefficient (below).
        % Third output neTable has per-point zX, zY, NE values.
        % Requires aggregate() first.
        %
        % See also: exploreFNIRS.core.plotNeuralEfficiency

            if ~obj.isAggregated
                error('exploreFNIRS:core:Experiment:plotNeuralEfficiency', ...
                    'Call aggregate() before plotNeuralEfficiency()');
            end
            varargin = obj.injectColorScheme(varargin);
            % Inject Device from data if not explicitly provided
            if ~any(strcmpi(varargin(1:2:end), 'Device'))
                dev = obj.resolveDevice();
                if ~isempty(dev)
                    varargin = [varargin, {'Device', dev}];
                end
            end
            [fig, stats, neTable] = exploreFNIRS.core.plotNeuralEfficiency( ...
                obj.groups, 'InfoVar', infoVar, varargin{:});
        end


        function [fig, results] = plotLME(obj, varargin)
        % PLOTLME Linear Mixed Effects analysis with bar chart and topo
        %
        %   [fig, results] = ex.plotLME()
        %   [fig, results] = ex.plotLME('Biomarkers', {'HbO'}, 'Channels', 1:5)
        %   [fig, results] = ex.plotLME('ShowTopo', true)
        %
        % Fits LME models per channel using the current groupby variables
        % as fixed effects. Requires aggregate() first.
        %
        % See also: exploreFNIRS.core.plotLME

            if ~obj.isAggregated
                error('exploreFNIRS:core:Experiment:plotLME', ...
                    'Call aggregate() before plotLME()');
            end
            varargin = obj.injectColorScheme(varargin);
            varargin = obj.injectStatWindow(varargin);
            varargin = obj.injectTimeModel(varargin);
            if ~any(strcmpi(varargin(1:2:end), 'Device'))
                dev = obj.resolveDevice();
                if ~isempty(dev)
                    varargin = [varargin, {'Device', dev}];
                end
            end
            [fig, results] = exploreFNIRS.core.plotLME(obj.groups, ...
                obj.groupByVars, varargin{:});
        end


        function [fig, results] = plotAuxLME(obj, auxField, varargin)
        % PLOTAUXLME LME analysis with bar chart for auxiliary data
        %
        %   [fig, results] = ex.plotAuxLME('heartRate')
        %   [fig, results] = ex.plotAuxLME('accelerometer', 'Channels', 1:2)
        %
        % Convenience wrapper for plotLME with DataType='Aux'.
        % Requires aggregate() first.
        %
        % See also: exploreFNIRS.core.plotLME, statsAuxLME

            if ~obj.isAggregated
                error('exploreFNIRS:core:Experiment:plotAuxLME', ...
                    'Call aggregate() before plotAuxLME()');
            end
            varargin = obj.injectColorScheme(varargin);
            varargin = obj.injectTimeModel(varargin);
            [fig, results] = exploreFNIRS.core.plotLME(obj.groups, ...
                obj.groupByVars, 'DataType', 'Aux', 'AuxField', auxField, ...
                varargin{:});
        end


        function [fig, results] = plotInfoLME(obj, infoVar, varargin)
        % PLOTINFOLME LME analysis with bar chart for info/behavioral variables
        %
        %   [fig, results] = ex.plotInfoLME('reactionTime')
        %   [fig, results] = ex.plotInfoLME('accuracy', 'AllInteractions', true)
        %
        % Fits a single LME model for the specified info variable and
        % renders a bar chart of F-statistics per ANOVA term.
        % Requires groupby() first (does NOT require aggregate).
        %
        % See also: exploreFNIRS.core.plotInfoLME, statsInfoLME

            if ~obj.isGrouped
                error('exploreFNIRS:core:Experiment:plotInfoLME', ...
                    'Call groupby() before plotInfoLME()');
            end
            selTable = obj.getSelectedTable();
            varargin = obj.injectColorScheme(varargin);
            [fig, results] = exploreFNIRS.core.plotInfoLME(selTable, ...
                infoVar, obj.groupByVars, varargin{:});
        end


        function [fig, results] = plotTopoLME(obj, varargin)
        % PLOTTOPOLME Topographic map of LME ANOVA statistics
        %
        %   [fig, results] = ex.plotTopoLME()
        %   [fig, results] = ex.plotTopoLME('SigType', 'q', 'Biomarkers', {'HbO'})
        %   [fig, results] = ex.plotTopoLME('Projection', '2D')
        %
        % Renders significant statistics from LME ANOVA onto a 3D brain
        % surface (default) or 2D probe layout. Use 'Projection','2D'
        % for flat probe plots. Requires aggregate() first.
        %
        % See also: exploreFNIRS.core.plotTopoLME, plotLME

            if ~obj.isAggregated
                error('exploreFNIRS:core:Experiment:plotTopoLME', ...
                    'Call aggregate() before plotTopoLME()');
            end
            [fig, results] = exploreFNIRS.core.plotTopoLME(obj.groups, ...
                obj.groupByVars, varargin{:});
        end


        function [fig, results] = plotTopoROILME(obj, varargin)
        % PLOTTOPOROILME ROI-level LME topo (2D or 3D)
        %
        %   [fig, results] = ex.plotTopoROILME()
        %   [fig, results] = ex.plotTopoROILME('Biomarkers', {'HbO'})
        %   [fig, results] = ex.plotTopoROILME('Projection', '2D')
        %
        % Convenience wrapper for plotTopoLME with DataType='ROI'.
        % Broadcasts each ROI's statistic to constituent channels.
        % Use 'Projection','2D' for flat probe plots with ROI labels.
        % Requires aggregate() first.
        %
        % See also: exploreFNIRS.core.plotTopoLME, plotLME, statsROILME

            if ~obj.isAggregated
                error('exploreFNIRS:core:Experiment:plotTopoROILME', ...
                    'Call aggregate() before plotTopoROILME()');
            end
            varargin = obj.injectColorScheme(varargin);
            [fig, results] = exploreFNIRS.core.plotTopoLME(obj.groups, ...
                obj.groupByVars, 'DataType', 'ROI', varargin{:});
        end


        function results = statsFitLME(obj, varargin)
        % STATSFITLME Fit LME models (statistics only, no visualization)
        %
        %   results = ex.statsFitLME()
        %   results = ex.statsFitLME('Biomarkers', {'HbO'}, 'Channels', 1:5)
        %
        % Fits LME models per channel using the current groupby variables
        % as fixed effects. Returns statistical results without any plots.
        % Requires aggregate() first.
        %
        % For combined analysis + visualization, use plotLME() instead.
        %
        % See also: exploreFNIRS.stats.fitLME, plotLME

            if ~obj.isAggregated
                error('exploreFNIRS:core:Experiment:statsFitLME', ...
                    'Call aggregate() before statsFitLME()');
            end
            varargin = obj.injectStatWindow(varargin);
            varargin = obj.injectTimeModel(varargin);
            % Diagnose between-subjects confounds once, up front, and silence
            % the per-channel "Hessian"/rank-deficiency spam during the fit.
            obj.warnBetweenSubjectConfound(obj.groupByVars, varargin);
            % With 2+ non-time grouping factors the default model is ADDITIVE
            % (main effects only). 'Group + Condition' is easily mistaken for
            % 'Group x Condition', so say so and point to the interaction flag.
            % Scan NAME positions only; stay silent when the interaction was
            % requested or an explicit CustomFormula overrides the auto-formula.
            nonTime = setdiff(obj.groupByVars, {'Time','time'}, 'stable');
            keys = varargin(1:2:end);
            allIntOn = false;
            ki = find(strcmpi(keys, 'AllInteractions'), 1);
            if ~isempty(ki) && numel(varargin) >= 2*ki
                v = varargin{2*ki};
                allIntOn = (islogical(v) || isnumeric(v)) && ~isempty(v) && all(logical(v(:)));
            end
            hasCustom = any(strcmpi(keys, 'CustomFormula'));
            if numel(nonTime) >= 2 && ~allIntOn && ~hasCustom
                warning('exploreFNIRS:statsLME:additiveModel', ...
                    ['Fitting an ADDITIVE model %s (main effects only). For the ', ...
                     'Group x Condition interaction pass ''AllInteractions'', true. ', ...
                     'If a between-subjects confound note also appeared, the ', ...
                     'interaction may still be inestimable.'], ...
                    strjoin(nonTime, ' + '));
            end
            cleanupObj = exploreFNIRS.core.Experiment.suppressFitWarnings(); %#ok<NASGU>
            results = exploreFNIRS.stats.fitLME(obj.groups, ...
                obj.groupByVars, varargin{:});
        end


        function results = statsInfoLME(obj, infoVar, varargin)
        % STATSINFOLME Fit LME model for an info/behavioral variable
        %
        %   results = ex.statsInfoLME('reactionTime')
        %   results = ex.statsInfoLME('accuracy', 'AllInteractions', true)
        %
        % Fits a single LME model using the specified info variable as the
        % response and the current groupby variables as fixed effects.
        % Does NOT require aggregate() - works directly from the dataTable.
        % Requires groupby() first.
        %
        % Results are compatible with statsRunContrasts() and statsSummarize().
        %
        % See also: exploreFNIRS.stats.fitInfoLME, statsFitLME

            if ~obj.isGrouped
                error('exploreFNIRS:core:Experiment:statsInfoLME', ...
                    'Call groupby() before statsInfoLME()');
            end
            selTable = obj.getSelectedTable();
            % Diagnose between-subjects confounds once, up front, and silence
            % the per-channel "Hessian"/rank-deficiency spam during the fit.
            obj.warnBetweenSubjectConfound(obj.groupByVars, varargin);
            cleanupObj = exploreFNIRS.core.Experiment.suppressFitWarnings(); %#ok<NASGU>
            results = exploreFNIRS.stats.fitInfoLME(selTable, infoVar, ...
                obj.groupByVars, varargin{:});
        end


        function results = statsAuxLME(obj, auxField, varargin)
        % STATSAUXLME Fit LME models for auxiliary data channels
        %
        %   results = ex.statsAuxLME('heartRate')
        %   results = ex.statsAuxLME('accelerometer', 'Channels', 1:2)
        %
        % Convenience wrapper for statsFitLME with DataType='Aux'.
        % Fits LME models per aux channel using the current groupby
        % variables as fixed effects. Requires aggregate() first.
        %
        % Results are compatible with statsRunContrasts() and statsSummarize().
        %
        % See also: exploreFNIRS.stats.fitLME, statsFitLME

            if ~obj.isAggregated
                error('exploreFNIRS:core:Experiment:statsAuxLME', ...
                    'Call aggregate() before statsAuxLME()');
            end
            varargin = obj.injectStatWindow(varargin);
            varargin = obj.injectTimeModel(varargin);
            results = exploreFNIRS.stats.fitLME(obj.groups, ...
                obj.groupByVars, 'DataType', 'Aux', 'AuxField', auxField, ...
                varargin{:});
        end


        function results = statsROILME(obj, varargin)
        % STATSROILME Fit LME models for ROI-level data
        %
        %   results = ex.statsROILME()
        %   results = ex.statsROILME('Biomarkers', {'HbO'}, 'Channels', 1:3)
        %
        % Convenience wrapper for statsFitLME with DataType='ROI'.
        % Fits LME models per ROI using the current groupby variables
        % as fixed effects. Requires aggregate() first. Use 'Channels'
        % to select specific ROI indices.
        %
        % See also: exploreFNIRS.stats.fitLME, statsFitLME

            if ~obj.isAggregated
                error('exploreFNIRS:core:Experiment:statsROILME', ...
                    'Call aggregate() before statsROILME()');
            end
            varargin = obj.injectStatWindow(varargin);
            varargin = obj.injectTimeModel(varargin);
            results = exploreFNIRS.stats.fitLME(obj.groups, ...
                obj.groupByVars, 'DataType', 'ROI', varargin{:});
        end


        function results = statsAutoLME(obj, varargin)
        % STATSAUTOLME Automatic per-channel LME model selection
        %
        %   results = ex.statsAutoLME()
        %   results = ex.statsAutoLME('Biomarkers', {'HbO'}, 'Channels', 1:5)
        %   results = ex.statsAutoLME('Criterion', 'BIC', 'DeltaThreshold', 4)
        %
        % Forward stepwise LME model selection per channel using AIC/BIC.
        % Auto-discovers which factors matter for each channel independently.
        % Results are compatible with statsSummarize() and statsRunContrasts().
        % Requires aggregate() first.
        %
        %   % Force a per-trial info variable as a fixed-effect covariate:
        %   results = ex.statsAutoLME('Covariates', {'RT'})
        %
        % Continuous covariates are entered UNCENTERED; consider mean-centering
        % (e.g. zscore) before passing so the group intercepts stay
        % interpretable. A forced covariate that is constant within every
        % subject triggers the between-subjects confound warning.
        %
        % See also: exploreFNIRS.stats.autoModelLME, statsFitLME

            if ~obj.isAggregated
                error('exploreFNIRS:core:Experiment:statsAutoLME', ...
                    'Call aggregate() before statsAutoLME()');
            end
            varargin = obj.injectStatWindow(varargin);
            varargin = obj.injectTimeModel(varargin);
            % Forward selection guards auto-discovered factors against a
            % between-subjects confound, but FORCED terms (Covariates /
            % ForcedTerms) bypass selection - so check them up front: a forced
            % covariate that is constant within every subject is confounded
            % with the (1|SubjectID) random intercept and yields NaN rows.
            forced = {};
            keys = varargin(1:2:end);
            for nm = {'Covariates', 'ForcedTerms'}
                fi = find(strcmpi(keys, nm{1}), 1);
                if ~isempty(fi) && numel(varargin) >= 2*fi
                    v = varargin{2*fi};
                    if iscell(v)
                        forced = [forced, v(:)']; %#ok<AGROW>
                    elseif ischar(v) || isstring(v)
                        forced = [forced, {char(v)}]; %#ok<AGROW>
                    end
                end
            end
            if ~isempty(forced)
                obj.warnBetweenSubjectConfound(unique(forced, 'stable'), varargin);
            end
            % autoModelLME fits fitlme repeatedly per channel/candidate model;
            % suppress the raw MATLAB Hessian/rank-deficiency spam here (as
            % statsFitLME/statsInfoLME do) so the consolidated diagnostic above
            % is the user-facing message.
            cleanupObj = exploreFNIRS.core.Experiment.suppressFitWarnings(); %#ok<NASGU>
            results = exploreFNIRS.stats.autoModelLME(obj.groups, ...
                obj.groupByVars, varargin{:});
        end


        function results = statsAutoROILME(obj, varargin)
        % STATSAUTOROILME Automatic per-ROI LME model selection
        %
        %   results = ex.statsAutoROILME()
        %   results = ex.statsAutoROILME('Biomarkers', {'HbO'}, 'Channels', 1:3)
        %
        % Convenience wrapper for statsAutoLME with DataType='ROI'.
        % Requires aggregate() first and ROIs defined.
        %
        % See also: exploreFNIRS.stats.autoModelLME, statsAutoLME

            if ~obj.isAggregated
                error('exploreFNIRS:core:Experiment:statsAutoROILME', ...
                    'Call aggregate() before statsAutoROILME()');
            end
            varargin = obj.injectStatWindow(varargin);
            varargin = obj.injectTimeModel(varargin);
            results = exploreFNIRS.stats.autoModelLME(obj.groups, ...
                obj.groupByVars, 'DataType', 'ROI', varargin{:});
        end


        function results = statsAutoInfoLME(obj, infoVar, varargin)
        % STATSAUTOINFOLME Auto model selection with behavioral response
        %
        %   results = ex.statsAutoInfoLME('reactionTime')
        %   results = ex.statsAutoInfoLME('accuracy', 'Biomarkers', {'HbO'})
        %
        % Forward stepwise selection per channel where the info variable is
        % the response and each channel's biomarker value is a candidate
        % predictor. Discovers whether brain activation predicts the
        % behavioral outcome. Requires aggregate() first.
        %
        % See also: exploreFNIRS.stats.autoModelLME, statsAutoLME

            if ~obj.isAggregated
                error('exploreFNIRS:core:Experiment:statsAutoInfoLME', ...
                    'Call aggregate() before statsAutoInfoLME()');
            end
            varargin = obj.injectStatWindow(varargin);
            varargin = obj.injectTimeModel(varargin);
            results = exploreFNIRS.stats.autoModelLME(obj.groups, ...
                obj.groupByVars, 'ResponseVar', infoVar, varargin{:});
        end


        function contrastResults = statsRunContrasts(obj, lmeResults, varargin)
        % STATSRUNCONTRASTS Post-hoc contrasts with FDR correction
        %
        %   results = ex.statsFitLME('Biomarkers', {'HbO'});
        %   cr = ex.statsRunContrasts(results);
        %   cr = ex.statsRunContrasts(results, 'FDRThreshold', 0.01)
        %
        % Takes output from statsFitLME and runs post-hoc contrasts per
        % channel, then applies FDR correction across channels.
        %
        % See also: exploreFNIRS.stats.runContrasts, statsFitLME

            contrastResults = exploreFNIRS.stats.runContrasts( ...
                lmeResults, varargin{:});
        end


        function T = statsSummarize(obj, lmeResults, varargin) %#ok<INUSL>
        % STATSSUMMARIZE Publication-ready summary table from results
        %
        %   results = ex.statsFitLME('Biomarkers', {'HbO'});
        %   T = ex.statsSummarize(results)
        %   T = ex.statsSummarize(results, 'Type', 'anova', 'Format', 'apa')
        %   T = ex.statsSummarize(results, 'Type', 'contrasts')
        %   T = ex.statsSummarize(results, 'Type', 'fit')
        %
        %   % Correlation stats from plotScatter
        %   [fig, stats] = ex.plotScatter('reactionTime', 'Biomarkers', {'HbO'});
        %   T = ex.statsSummarize(stats, 'Type', 'correlations')
        %
        % Formats LME or correlation results into publication-ready tables.
        %
        % See also: exploreFNIRS.stats.summarize, statsFitLME, plotScatter

            T = exploreFNIRS.stats.summarize(lmeResults, varargin{:});
        end


        function results = statsClusterPermutation(obj, lmeResults, varargin)
        % STATSCLUSTERPERMUTATION Cluster-based permutation testing
        %
        %   results = ex.statsFitLME('Biomarkers', {'HbO'});
        %   cp = ex.statsClusterPermutation(results)
        %   cp = ex.statsClusterPermutation(results, 'Permutations', 500)
        %
        % Performs nonparametric cluster-based permutation testing using
        % spatial adjacency to identify significant channel clusters.
        % Controls family-wise error rate at the cluster level.
        %
        % See also: exploreFNIRS.stats.clusterPermutation, statsFitLME

            results = exploreFNIRS.stats.clusterPermutation( ...
                lmeResults, obj.data, varargin{:});
        end


        function results = statsPermTest(obj, varargin)
        % STATSPERMTEST Non-parametric permutation test for paired comparisons
        %
        %   results = ex.statsPermTest()
        %   results = ex.statsPermTest('Biomarkers', {'HbO'}, 'NumPerm', 1000)
        %
        % Performs sign-flip permutation testing for 2-condition
        % within-subject comparisons. Requires aggregate() with exactly
        % 2 groups.
        %
        % See also: exploreFNIRS.stats.permTest, statsFitLME

            if ~obj.isAggregated
                error('exploreFNIRS:core:Experiment:statsPermTest', ...
                    'Call aggregate() before statsPermTest()');
            end
            varargin = obj.injectStatWindow(varargin);
            results = exploreFNIRS.stats.permTest(obj.groups, ...
                obj.groupByVars, varargin{:});
        end


        function results = statsEffectSize(obj, varargin)
        % STATSEFFECTSIZE Effect size with bootstrap confidence intervals
        %
        %   results = ex.statsEffectSize()
        %   results = ex.statsEffectSize('Method', 'hedges_g', 'NumBoot', 2000)
        %
        % Computes effect sizes between 2 conditions with bootstrap CIs.
        % Requires aggregate() with exactly 2 groups.
        %
        % See also: exploreFNIRS.stats.effectSize, statsFitLME

            if ~obj.isAggregated
                error('exploreFNIRS:core:Experiment:statsEffectSize', ...
                    'Call aggregate() before statsEffectSize()');
            end
            varargin = obj.injectStatWindow(varargin);
            results = exploreFNIRS.stats.effectSize(obj.groups, ...
                obj.groupByVars, varargin{:});
        end


        function results = statsROIPermTest(obj, varargin)
        % STATSROIPERMTEST Non-parametric permutation test for ROI-level data
        %
        %   results = ex.statsROIPermTest()
        %   results = ex.statsROIPermTest('Biomarkers', {'HbO'}, 'NumPerm', 1000)
        %
        % Convenience wrapper for statsPermTest with DataType='ROI'.
        % Performs sign-flip permutation testing per ROI. Requires
        % aggregate() with exactly 2 groups and ROIs defined.
        %
        % See also: exploreFNIRS.stats.permTest, statsPermTest

            if ~obj.isAggregated
                error('exploreFNIRS:core:Experiment:statsROIPermTest', ...
                    'Call aggregate() before statsROIPermTest()');
            end
            varargin = obj.injectStatWindow(varargin);
            results = exploreFNIRS.stats.permTest(obj.groups, ...
                obj.groupByVars, 'DataType', 'ROI', varargin{:});
        end


        function results = statsROIEffectSize(obj, varargin)
        % STATSROIEFFECTSIZE Effect size with bootstrap CIs for ROI-level data
        %
        %   results = ex.statsROIEffectSize()
        %   results = ex.statsROIEffectSize('Method', 'hedges_g', 'NumBoot', 2000)
        %
        % Convenience wrapper for statsEffectSize with DataType='ROI'.
        % Computes effect sizes per ROI. Requires aggregate() with
        % exactly 2 groups and ROIs defined.
        %
        % See also: exploreFNIRS.stats.effectSize, statsEffectSize

            if ~obj.isAggregated
                error('exploreFNIRS:core:Experiment:statsROIEffectSize', ...
                    'Call aggregate() before statsROIEffectSize()');
            end
            varargin = obj.injectStatWindow(varargin);
            results = exploreFNIRS.stats.effectSize(obj.groups, ...
                obj.groupByVars, 'DataType', 'ROI', varargin{:});
        end


        function [T, stats] = brainBehavior(obj, infoVar, varargin)
        % BRAINBEHAVIOR Brain-behavior correlation table (one call)
        %
        %   T = ex.brainBehavior('reactionTime')
        %   T = ex.brainBehavior('Age', 'Biomarkers', {'HbO'}, 'CorrType', 'Spearman')
        %   T = ex.brainBehavior('Score', 'Format', 'latex')
        %   [T, stats] = ex.brainBehavior('RT', 'Channels', 1:5)
        %
        % Computes per-channel correlations between a behavioral/info
        % variable and fNIRS biomarker data. Returns a publication-ready
        % table via summarize(stats, 'Type', 'correlations').
        %
        % All plotScatter name-value parameters are accepted (Biomarkers,
        % Channels, CorrType, etc.) plus summarize parameters (Format).
        %
        % Requires aggregate() first.
        %
        % See also: plotScatter, statsSummarize

            if ~obj.isAggregated
                error('exploreFNIRS:core:Experiment:brainBehavior', ...
                    'Call aggregate() before brainBehavior()');
            end

            % Separate summarize params from plotScatter params
            summarizeKeys = {'Format', 'SigThreshold'};
            summarizeArgs = {};
            scatterArgs = {};
            i = 1;
            while i <= length(varargin)
                if ischar(varargin{i}) && any(strcmpi(varargin{i}, summarizeKeys))
                    summarizeArgs = [summarizeArgs, varargin(i:i+1)]; %#ok<AGROW>
                    i = i + 2;
                else
                    scatterArgs = [scatterArgs, varargin(i)]; %#ok<AGROW>
                    i = i + 1;
                end
            end

            % Run scatter headlessly (PlotTopo for per-channel, Visible off)
            scatterArgs = [scatterArgs, {'PlotTopo', true, 'SavePath', ''}];
            [fig, stats] = obj.plotScatter(infoVar, scatterArgs{:});
            if ~isempty(fig) && isvalid(fig)
                close(fig);
            end

            % Extract metadata for summarize
            bioArgs = {};
            chArgs = {};
            corrArgs = {};
            for k = 1:2:length(scatterArgs)
                key = scatterArgs{k};
                if strcmpi(key, 'Biomarkers')
                    bioArgs = {'Biomarkers', scatterArgs{k+1}};
                elseif strcmpi(key, 'Channels')
                    chArgs = {'Channels', scatterArgs{k+1}};
                elseif strcmpi(key, 'CorrType')
                    corrArgs = {'CorrType', scatterArgs{k+1}};
                end
            end

            T = exploreFNIRS.stats.summarize(stats, ...
                'Type', 'correlations', ...
                'InfoVar', infoVar, ...
                bioArgs{:}, chArgs{:}, corrArgs{:}, ...
                summarizeArgs{:});

            % Fail loud on too few observations instead of returning a silent
            % blank/NaN table. brainBehavior correlates ONE value per
            % observation unit (subject / hierarchy leaf after averaging)
            % against the biomarker, so a single subject (or single group leaf)
            % yields N<3 and nothing to correlate. Tell the user why and where
            % to go for a within-subject, trial-level relationship.
            maxN = 0;
            haveN = false;
            if isstruct(stats) && isfield(stats, 'N')
                for si = 1:numel(stats)
                    Nsi = stats(si).N;
                    if ~isempty(Nsi) && isnumeric(Nsi)
                        haveN = true;
                        maxN = max(maxN, max(double(Nsi(:))));
                    end
                end
            end
            % Only flag the genuine "nothing to correlate" case (matches the
            % N>=3 gate inside plotScatter, where the table is otherwise
            % blank/NaN). Skip when stats carried no N at all - that is a
            % different failure and a low-N message would mislead.
            if haveN && maxN < 3
                warning('exploreFNIRS:core:Experiment:brainBehaviorLowN', ...
                    ['brainBehavior(''%s'') has at most N=%d observation(s) per ', ...
                     'channel - too few to correlate. Brain-behavior correlation ', ...
                     'is computed ACROSS observation units (subjects / hierarchy ', ...
                     'leaves after averaging), not across trials; with one ', ...
                     'subject there is nothing to correlate. For a within-subject ', ...
                     'trial-level relationship, aggregate with avgMode ''none'' ', ...
                     '(per-trial rows) then model the table directly - e.g. ', ...
                     'ex.statsAutoLME(''Covariates'', {''%s''}) or fitlme on the ', ...
                     'per-trial info+biomarker values.'], ...
                    infoVar, maxN, infoVar);
            end
        end


        function T = infoTable(obj)
        % INFOTABLE Return the selected metadata as a plain table
        %
        %   T = ex.infoTable()
        %
        % Useful for behavioral analysis, summary statistics, or exporting
        % metadata without running the fNIRS aggregation pipeline.

            T = obj.getSelectedTable();
        end


        function summary(obj)
        % SUMMARY Display experiment overview
        %
        %   ex.summary()

            fprintf('\n=== Experiment Summary ===\n');
            fprintf('Total segments: %d\n', length(obj.data));
            fprintf('Selected: %d\n', sum(obj.selectedIdx));

            % Show available metadata variables
            vars = obj.dataTable.Properties.VariableNames;
            fprintf('Metadata variables: %s\n', strjoin(vars, ', '));

            % Show unique values for key variables
            keyVars = intersect({'SubjectID','Group','Condition','Session'}, vars, 'stable');
            for i = 1:length(keyVars)
                v = keyVars{i};
                vals = unique(obj.dataTable.(v)(obj.selectedIdx));
                if isnumeric(vals)
                    valStr = strjoin(arrayfun(@num2str, vals, 'UniformOutput', false), ', ');
                else
                    valStr = strjoin(string(vals), ', ');
                end
                fprintf('  %s: [%s] (%d unique)\n', v, valStr, length(vals));
            end

            % Show hierarchy
            validH = intersect(obj.hierarchy, vars, 'stable');
            fprintf('Hierarchy: %s\n', strjoin(validH, ' > '));

            % Show preprocessing settings
            s = obj.settings;
            fprintf('Settings:\n');
            fprintf('  Baseline: [%.1f, %.1f]s (enabled: %s)\n', ...
                s.baseline(1), s.baseline(2), mat2str(s.useBaseline));
            fprintf('  Resample: %.2fs bins, task start: %.1fs\n', ...
                s.resampleRate, s.taskStart);

            % Show grouping state
            if obj.isGrouped
                fprintf('Grouped by: %s (%d groups)\n', ...
                    strjoin(obj.groupByVars, ', '), length(obj.groups));
                for g = 1:length(obj.groups)
                    nSeg = size(obj.groups(g).gbyTables, 1);
                    aggStr = '';
                    if obj.isAggregated && ~isempty(obj.groups(g).gbyGrand)
                        nObs = size(obj.groups(g).gbyGrand.HbO.data, 3);
                        aggStr = sprintf(' -> %d observations after averaging', nObs);
                    end
                    fprintf('  [%d] %s: %d segments%s\n', ...
                        g, obj.groups(g).label, nSeg, aggStr);
                end
            else
                fprintf('Not grouped (call groupby() to define groups)\n');
            end

            if obj.isAggregated
                fprintf('Status: Aggregated\n');
            elseif obj.isGrouped
                fprintf('Status: Grouped (call aggregate() to compute averages)\n');
            else
                fprintf('Status: Ready (call select() and/or groupby())\n');
            end
            fprintf('\n');
        end


        function T = demographicsTable(obj, varargin)
        % DEMOGRAPHICSTABLE Publication-style Table 1 demographics summary
        %
        %   T = ex.demographicsTable()
        %   T = ex.demographicsTable('Variables', {'Age','Sex'})
        %   T = ex.demographicsTable('GroupBy', 'Group')
        %   T = ex.demographicsTable('GroupBy', 'Group', 'Format', 'console')
        %
        % Summarizes participant characteristics at the subject level.
        % No preconditions — works on selected data at any stage.
        %
        % See also: exploreFNIRS.report.demographicsTable

            T = exploreFNIRS.report.demographicsTable(obj, varargin{:});
        end


        function T = behavioralTable(obj, variables, varargin)
        % BEHAVIORALTABLE Descriptive stats, comparisons, or correlations for behavioral data
        %
        %   T = ex.behavioralTable({'RT','Accuracy'})
        %   T = ex.behavioralTable({'RT'}, 'Type', 'comparisons', 'GroupBy', 'Condition')
        %   T = ex.behavioralTable({'RT','WM'}, 'Type', 'correlations', 'Format', 'latex')
        %
        % See also: exploreFNIRS.stats.behavioralTable

            T = exploreFNIRS.stats.behavioralTable(obj, variables, varargin{:});
        end


        function result = connectivity(obj, varargin)
        % CONNECTIVITY Compute within-subject connectivity matrices per group
        %
        %   result = ex.connectivity()
        %   result = ex.connectivity('Method', 'pearson', 'Biomarker', 'HbO')
        %   result = ex.connectivity('TimeWindow', [5, 25], 'Channels', 1:16)
        %   result = ex.connectivity('Blocks', blocks)
        %   result = ex.connectivity('Align', 'union')
        %
        % For each group, computes a connectivity matrix per subject, then
        % averages across subjects. Requires groupby() first but does NOT
        % require aggregate() (works directly on selected fNIRS data).
        %
        % When 'Blocks' is provided, computes connectivity for each block's
        % time window and returns a struct array with one element per block.
        %
        % Name-Value Parameters:
        %   Method       - 'pearson' (default), 'spearman', 'xcorr', 'coherence', 'wcoherence'
        %   Biomarker    - 'HbO' (default), 'HbR', 'HbTotal', 'HbDiff', 'CBSI'
        %   Channels     - Channel indices (default: all good channels)
        %   TimeWindow   - [start, end] seconds (default: full range)
        %   CouplingArgs - Extra args for coupling function (default: {})
        %   UseROI       - Use ROI-level data instead of channels (default: false)
        %   Blocks       - Block definition struct array from pf2.data.defineBlocks
        %                  When provided, computes connectivity per block.
        %   Align        - Channel alignment mode for group aggregation:
        %                  'union' (default) - all channels, NaN where missing
        %                  'intersection' - only channels in all subjects
        %                  numeric 0-1 - channels in >= threshold fraction
        %
        % Outputs (without Blocks):
        %   result - Struct array (one per group) with fields:
        %     .Mean      - [C x C] mean connectivity matrix
        %     .SD        - [C x C] standard deviation
        %     .SEM       - [C x C] standard error
        %     .N         - Number of subjects
        %     .matrices  - {N x 1} cell of individual matrices
        %     .label     - Group label
        %     .method    - Coupling method
        %     .biomarker - Biomarker used
        %     .channels  - Channel indices
        %
        % Outputs (with Blocks):
        %   result - Struct array (one per block) with fields:
        %     .blockNumber - Block index
        %     .startTime   - Block start time
        %     .endTime     - Block end time
        %     .blockInfo   - Block .info struct
        %     .groups      - Per-group struct array (same format as above)
        %
        % See also: exploreFNIRS.connectivity.computeMatrix,
        %   exploreFNIRS.connectivity.plotMatrix, pf2.data.defineBlocks

            if ~obj.isGrouped
                error('exploreFNIRS:core:Experiment:connectivity', ...
                    'Call groupby() before connectivity()');
            end

            % Extract Blocks and Align parameters (not forwarded to computeMatrix)
            [blocks, fwdArgs] = extractBlocksArg(varargin);
            [align, fwdArgs] = extractAlignArg(fwdArgs);

            if isempty(blocks)
                % Standard: compute for full time range
                result = computeConnectivityGroups(obj.groups, fwdArgs, align);
            else
                % Block-wise: compute per block
                nBlocks = length(blocks);
                result = struct([]);
                for b = 1:nBlocks
                    tw = [blocks(b).startTime, blocks(b).endTime];
                    blockArgs = [fwdArgs, 'TimeWindow', tw];

                    result(b).blockNumber = b;
                    result(b).startTime = blocks(b).startTime;
                    result(b).endTime = blocks(b).endTime;
                    result(b).blockInfo = blocks(b).info;
                    result(b).groups = computeConnectivityGroups( ...
                        obj.groups, blockArgs, align);
                end
                fprintf('Computed connectivity for %d blocks across %d groups.\n', ...
                    nBlocks, length(obj.groups));
            end
        end


        function result = graphMetrics(obj, varargin)
        % GRAPHMETRICS Graph theory metrics from within-group connectivity
        %
        %   result = ex.graphMetrics()
        %   result = ex.graphMetrics('Method', 'pearson', 'Threshold', 0.3)
        %   result = ex.graphMetrics('Metrics', {'degree', 'modularity'})
        %   result = ex.graphMetrics('Blocks', blocks)
        %
        % For each group, computes a connectivity matrix (via connectivity()),
        % thresholds it, and computes selected graph theory metrics. Requires
        % groupby() first.
        %
        % Name-Value Parameters:
        %   Method          - Coupling method for connectivity (default: 'pearson')
        %   Biomarker       - 'HbO' (default), 'HbR', etc.
        %   Threshold       - Threshold value (default: 0.3)
        %   ThresholdMethod - 'absolute' (default), 'proportional', 'significance'
        %   Binarize        - Binarize graph (default: false)
        %   Metrics         - Cell array of metric names (default: all except smallWorld)
        %   Gamma           - Modularity resolution (default: 1)
        %   NReplicates     - Modularity replicates (default: 100)
        %   NRandom         - Small-world null count (default: 100)
        %   Blocks          - Block struct array for block-wise analysis
        %   Align           - Channel alignment: 'union' (default), 'intersection'
        %   Channels        - Channel indices to include
        %   TimeWindow      - [start, end] seconds
        %   CouplingArgs    - Extra coupling args
        %   UseROI          - Use ROI data (default: false)
        %
        % Outputs:
        %   result - Struct array (one per group) with fields from computeMetrics
        %            plus .label (group name).
        %            When Blocks provided: struct array (one per block) with
        %            .blockNumber, .startTime, .endTime, .blockInfo, .groups.
        %
        % See also: exploreFNIRS.graph.computeMetrics,
        %   exploreFNIRS.graph.plotNetwork, exploreFNIRS.graph.metricsToTable

            if ~obj.isGrouped
                error('exploreFNIRS:core:Experiment:graphMetrics', ...
                    'Call groupby() before graphMetrics()');
            end

            % Separate graph-specific params from connectivity params
            graphParamNames = {'Threshold', 'ThresholdMethod', 'Binarize', ...
                'Metrics', 'Gamma', 'NReplicates', 'NRandom'};
            graphArgs = {};
            connArgs = {};

            i = 1;
            while i <= length(varargin)
                if ischar(varargin{i}) && any(strcmpi(varargin{i}, graphParamNames))
                    graphArgs = [graphArgs, varargin(i:i+1)]; %#ok<AGROW>
                    i = i + 2;
                else
                    connArgs = [connArgs, varargin(i)]; %#ok<AGROW>
                    i = i + 1;
                end
            end

            % Compute connectivity (handles Blocks internally)
            connResult = obj.connectivity(connArgs{:});

            % Check if block-wise
            if ~isempty(connResult) && isfield(connResult, 'groups')
                % Block-wise: connResult is struct array with .groups per block
                nBlocks = length(connResult);
                result = connResult;  % preserve block metadata
                for b = 1:nBlocks
                    nGrp = length(connResult(b).groups);
                    grpMetrics = struct([]);
                    for g = 1:nGrp
                        m = exploreFNIRS.graph.computeMetrics( ...
                            connResult(b).groups(g), graphArgs{:});
                        if isfield(connResult(b).groups(g), 'label')
                            m.label = connResult(b).groups(g).label;
                        end
                        if isempty(grpMetrics)
                            grpMetrics = m;
                        else
                            grpMetrics(g) = m;
                        end
                    end
                    result(b).groups = grpMetrics;
                end
            else
                % Standard: connResult is struct array (one per group)
                nGrp = length(connResult);
                result = struct([]);
                for g = 1:nGrp
                    m = exploreFNIRS.graph.computeMetrics( ...
                        connResult(g), graphArgs{:});
                    if isfield(connResult(g), 'label')
                        m.label = connResult(g).label;
                    end
                    if isempty(result)
                        result = m;
                    else
                        result(g) = m;
                    end
                end
            end
        end


        function result = hyperscanning(obj, varargin)
        % HYPERSCANNING Inter-brain synchrony analysis across paired subjects
        %
        %   result = ex.hyperscanning()
        %   result = ex.hyperscanning('Method', 'pearson', 'Permutations', 500)
        %   result = ex.hyperscanning('ManualPairs', {{1,2},{3,4}})
        %   result = ex.hyperscanning('Blocks', blocks)
        %
        % Pairs subjects using .info.DyadID metadata, computes cross-brain
        % coupling for each dyad, and aggregates into group statistics.
        % Operates on selected data directly (no aggregate needed).
        %
        % When 'Blocks' is provided, computes hyperscanning for each block's
        % time window and returns a struct array with one element per block.
        %
        % Name-Value Parameters:
        %   Method          - 'pearson' (default), 'spearman', 'xcorr', 'coherence', 'wcoherence'
        %   Biomarker       - 'HbO' (default), 'HbR', 'HbTotal', 'HbDiff', 'CBSI'
        %   ChannelPairing  - 'same' (default) or 'all'
        %   Channels        - Channel indices (default: intersection of good channels)
        %   TimeWindow      - [start, end] seconds
        %   Permutations    - Number of permutations for significance (default: 0, none)
        %   PThreshold      - Significance threshold (default: 0.05)
        %   ManualPairs     - Manual pairing override (see pairSubjects)
        %   DyadField       - Info field for dyad ID (default: 'DyadID')
        %   RoleField       - Info field for role (default: 'Role')
        %   CouplingArgs    - Extra args for coupling function (default: {})
        %   Blocks          - Block definition struct array from pf2.data.defineBlocks
        %                     When provided, computes hyperscanning per block.
        %   Align           - Channel alignment mode for group aggregation:
        %                     'union' (default) - all channels, NaN where missing
        %                     'intersection' - only channels in all subjects
        %                     numeric 0-1 - channels in >= threshold fraction
        %
        % Outputs (without Blocks):
        %   result - Struct with fields from computeGroup, plus:
        %     .pairs       - Pairs struct from pairSubjects
        %     .permutation - Permutation test result (if Permutations > 0)
        %
        % Outputs (with Blocks):
        %   result - Struct array (one per block) with fields:
        %     .blockNumber - Block index
        %     .startTime   - Block start time
        %     .endTime     - Block end time
        %     .blockInfo   - Block .info struct
        %     .coupling    - Hyperscanning result (same format as above)
        %
        % See also: exploreFNIRS.hyperscanning.pairSubjects,
        %   exploreFNIRS.hyperscanning.computeGroup,
        %   exploreFNIRS.hyperscanning.permutationTest, pf2.data.defineBlocks

            ip = inputParser;
            addParameter(ip, 'Method', 'pearson', @ischar);
            addParameter(ip, 'Biomarker', 'HbO', @ischar);
            addParameter(ip, 'ChannelPairing', 'same', @ischar);
            addParameter(ip, 'Channels', [], @isnumeric);
            addParameter(ip, 'TimeWindow', [], @(v) isnumeric(v) && (isempty(v) || length(v) == 2));
            addParameter(ip, 'Permutations', 0, @(v) isnumeric(v) && isscalar(v));
            addParameter(ip, 'PThreshold', 0.05, @isnumeric);
            addParameter(ip, 'ManualPairs', {}, @iscell);
            addParameter(ip, 'DyadField', 'DyadID', @ischar);
            addParameter(ip, 'RoleField', 'Role', @ischar);
            addParameter(ip, 'CouplingArgs', {}, @iscell);
            addParameter(ip, 'UseROI', false, @islogical);
            addParameter(ip, 'Blocks', [], @(x) isempty(x) || isstruct(x));
            addParameter(ip, 'Align', 'union', @(x) (ischar(x) || isstring(x)) || (isnumeric(x) && isscalar(x)));
            parse(ip, varargin{:});
            opts = ip.Results;

            selData = obj.getSelectedData();

            % Pair subjects (same pairs for all blocks)
            pairArgs = {};
            if ~isempty(opts.ManualPairs)
                pairArgs = [pairArgs, 'ManualPairs', {opts.ManualPairs}];
            end
            pairArgs = [pairArgs, 'DyadField', opts.DyadField, 'RoleField', opts.RoleField];

            pairs = exploreFNIRS.hyperscanning.pairSubjects(selData, pairArgs{:});

            if isempty(pairs)
                error('exploreFNIRS:core:Experiment:hyperscanning', ...
                    'No valid pairs found. Check .info.%s or use ManualPairs.', opts.DyadField);
            end

            % Build base args for computeGroup/computeDyad
            groupArgs = {'Method', opts.Method, 'Biomarker', opts.Biomarker, ...
                'ChannelPairing', opts.ChannelPairing};
            if ~isempty(opts.Channels)
                groupArgs = [groupArgs, 'Channels', opts.Channels];
            end
            if ~isempty(opts.CouplingArgs)
                groupArgs = [groupArgs, 'CouplingArgs', {opts.CouplingArgs}];
            end
            if opts.UseROI
                groupArgs = [groupArgs, 'UseROI', true];
            end

            alignMode = opts.Align;

            if isempty(opts.Blocks)
                % Standard: single time window
                coreArgs = groupArgs;
                if ~isempty(opts.TimeWindow)
                    coreArgs = [coreArgs, 'TimeWindow', opts.TimeWindow];
                end
                result = computeHyperscanningCore(selData, pairs, coreArgs, ...
                    opts.Permutations, opts.PThreshold, alignMode);
            else
                % Block-wise: iterate over blocks
                blocks = opts.Blocks;
                nBlocks = length(blocks);
                result = struct([]);
                for b = 1:nBlocks
                    tw = [blocks(b).startTime, blocks(b).endTime];
                    coreArgs = [groupArgs, 'TimeWindow', tw];

                    result(b).blockNumber = b;
                    result(b).startTime = blocks(b).startTime;
                    result(b).endTime = blocks(b).endTime;
                    result(b).blockInfo = blocks(b).info;
                    result(b).coupling = computeHyperscanningCore( ...
                        selData, pairs, coreArgs, ...
                        opts.Permutations, opts.PThreshold, alignMode);
                end
                fprintf('Computed hyperscanning for %d blocks across %d dyads.\n', ...
                    nBlocks, length(pairs));
            end
        end


        function result = hbica(obj, varargin)
        % HBICA Hyper-Brain ICA for inter-brain network detection
        %
        %   result = ex.hbica()
        %   result = ex.hbica('Biomarker', 'HbR', 'GOFThreshold', -0.5)
        %   result = ex.hbica('ManualPairs', {{1,2},{3,4}})
        %   result = ex.hbica('Blocks', blocks)
        %
        % Pairs subjects using .info.DyadID metadata, runs HB-ICA
        % decomposition for each dyad, and aggregates results.
        %
        % Name-Value Parameters:
        %   Biomarker        - 'HbO' (default), 'HbR', 'HbTotal', 'HbDiff', 'CBSI'
        %   Channels         - Channel indices (default: intersection of good channels)
        %   TimeWindow       - [start, end] seconds
        %   NumComponents    - ICA components (default: auto)
        %   VarianceRetained - PCA threshold (default: 0.99)
        %   Lags             - TDSEP lags (default: auto)
        %   GOFThreshold     - Inter-brain classification threshold (default: 0)
        %   Detrend          - Polynomial detrend order (default: 1)
        %   ZScore           - Z-score channels before concat (default: true)
        %   UseROI           - Use ROI-level data instead of channels (default: false)
        %   ManualPairs      - Manual pairing override (see pairSubjects)
        %   DyadField        - Info field for dyad ID (default: 'DyadID')
        %   RoleField        - Info field for role (default: 'Role')
        %   Blocks           - Block struct array from pf2.data.defineBlocks
        %
        % Outputs (without Blocks):
        %   result - Struct with fields:
        %     .dyads         - Cell array of per-dyad hbica results
        %     .dyadIDs       - Cell array of dyad ID strings
        %     .pairs         - Pairs struct from pairSubjects
        %     .summary       - Struct with .meanGOF, .nInterBrain per dyad
        %
        % Outputs (with Blocks):
        %   result - Struct array (one per block) with fields:
        %     .blockNumber, .startTime, .endTime, .blockInfo, .hbica
        %
        % See also: exploreFNIRS.hyperscanning.hbica,
        %   exploreFNIRS.hyperscanning.plotHBICA,
        %   exploreFNIRS.hyperscanning.pairSubjects

            ip = inputParser;
            addParameter(ip, 'Biomarker', 'HbO', @ischar);
            addParameter(ip, 'Channels', [], @isnumeric);
            addParameter(ip, 'TimeWindow', [], @(v) isnumeric(v) && (isempty(v) || length(v) == 2));
            addParameter(ip, 'NumComponents', 0, @(v) isnumeric(v) && isscalar(v));
            addParameter(ip, 'VarianceRetained', 0.99, @(v) isnumeric(v) && isscalar(v));
            addParameter(ip, 'Lags', [], @(v) isnumeric(v));
            addParameter(ip, 'GOFThreshold', 0, @(v) isnumeric(v) && isscalar(v));
            addParameter(ip, 'Detrend', 1, @(v) isnumeric(v) && isscalar(v));
            addParameter(ip, 'ZScore', true, @islogical);
            addParameter(ip, 'UseROI', false, @islogical);
            addParameter(ip, 'ManualPairs', {}, @iscell);
            addParameter(ip, 'DyadField', 'DyadID', @ischar);
            addParameter(ip, 'RoleField', 'Role', @ischar);
            addParameter(ip, 'Blocks', [], @(x) isempty(x) || isstruct(x));
            parse(ip, varargin{:});
            opts = ip.Results;

            selData = obj.getSelectedData();

            % Pair subjects
            pairArgs = {};
            if ~isempty(opts.ManualPairs)
                pairArgs = [pairArgs, 'ManualPairs', {opts.ManualPairs}];
            end
            pairArgs = [pairArgs, 'DyadField', opts.DyadField, 'RoleField', opts.RoleField];
            pairs = exploreFNIRS.hyperscanning.pairSubjects(selData, pairArgs{:});

            if isempty(pairs)
                error('exploreFNIRS:core:Experiment:hbica', ...
                    'No valid pairs found. Check .info.%s or use ManualPairs.', opts.DyadField);
            end

            % Build HB-ICA args
            hbicaArgs = {'Biomarker', opts.Biomarker, ...
                'NumComponents', opts.NumComponents, ...
                'VarianceRetained', opts.VarianceRetained, ...
                'GOFThreshold', opts.GOFThreshold, ...
                'Detrend', opts.Detrend, ...
                'ZScore', opts.ZScore};
            if ~isempty(opts.Channels)
                hbicaArgs = [hbicaArgs, 'Channels', opts.Channels];
            end
            if ~isempty(opts.Lags)
                hbicaArgs = [hbicaArgs, 'Lags', opts.Lags];
            end
            if opts.UseROI
                hbicaArgs = [hbicaArgs, 'UseROI', true];
            end

            if isempty(opts.Blocks)
                result = computeHBICAcore(selData, pairs, hbicaArgs, opts.TimeWindow);
            else
                blocks = opts.Blocks;
                nBlocks = length(blocks);
                result = struct([]);
                for b = 1:nBlocks
                    tw = [blocks(b).startTime, blocks(b).endTime];
                    result(b).blockNumber = b;
                    result(b).startTime = blocks(b).startTime;
                    result(b).endTime = blocks(b).endTime;
                    result(b).blockInfo = blocks(b).info;
                    result(b).hbica = computeHBICAcore(selData, pairs, hbicaArgs, tw);
                end
                fprintf('Computed HB-ICA for %d blocks across %d dyads.\n', ...
                    nBlocks, length(pairs));
            end
        end


        function fig = plotTopo(obj, varargin)
        % PLOTTOPO Group-level 2D topographic map
        %
        %   fig = ex.plotTopo()
        %   fig = ex.plotTopo('Biomarker', 'HbO', 'Time', 10)
        %   fig = ex.plotTopo('Layout', 'pergroup', 'SavePath', 'topo.png')
        %
        % See also: exploreFNIRS.core.plotTopo

            if ~obj.isAggregated
                error('exploreFNIRS:core:Experiment:plotTopo', ...
                    'Call aggregate() before plotting');
            end
            varargin = obj.injectColorScheme(varargin);
            % Inject Device from data if not explicitly provided
            if ~any(strcmpi(varargin(1:2:end), 'Device'))
                dev = obj.resolveDevice();
                if ~isempty(dev)
                    varargin = [varargin, {'Device', dev}];
                end
            end
            fig = exploreFNIRS.core.plotTopo(obj.groups, varargin{:});
        end


        function fig = plotHeatmap(obj, varargin)
        % PLOTHEATMAP Channel x time heatmap
        %
        %   fig = ex.plotHeatmap()
        %   fig = ex.plotHeatmap('Biomarker', 'HbO', 'SortChannels', 'amplitude')
        %   fig = ex.plotHeatmap('XLim', [-5 35], 'SavePath', 'heatmap.png')
        %
        % The visible time range is set at aggregate() time by
        % settings.viewPad (default [5,5] seconds, padding around
        % baseline-start and task-end). For visual cropping of an
        % already-wide view, pass 'XLim', [tmin tmax].
        %
        % See also: exploreFNIRS.core.plotHeatmap, plotTemporal

            if ~obj.isAggregated
                error('exploreFNIRS:core:Experiment:plotHeatmap', ...
                    'Call aggregate() before plotting');
            end
            varargin = obj.injectColorScheme(varargin);
            % Inject Device from data if not explicitly provided
            if ~any(strcmpi(varargin(1:2:end), 'Device'))
                dev = obj.resolveDevice();
                if ~isempty(dev)
                    varargin = [varargin, {'Device', dev}];
                end
            end
            fig = exploreFNIRS.core.plotHeatmap(obj.groups, varargin{:});
        end


        function fig = plotComposite(obj, panels, varargin)
        % PLOTCOMPOSITE Multi-panel publication figure
        %
        %   panels = {struct('type','temporal','args',{{'Biomarkers',{'HbO'}}}), ...
        %             struct('type','bar','args',{{'Biomarker','HbO'}})};
        %   fig = ex.plotComposite(panels, 'Layout', [1,2])
        %
        % See also: exploreFNIRS.core.plotComposite

            if ~obj.isAggregated
                error('exploreFNIRS:core:Experiment:plotComposite', ...
                    'Call aggregate() before plotting');
            end
            % Inject Device into topo panels that don't already have one
            dev = obj.resolveDevice();
            if ~isempty(dev)
                for pi = 1:length(panels)
                    if strcmpi(panels{pi}.type, 'topo') && isfield(panels{pi}, 'args')
                        pArgs = panels{pi}.args;
                        if ~any(strcmpi(pArgs(1:2:end), 'Device'))
                            panels{pi}.args = [pArgs, {'Device', dev}];
                        end
                    end
                end
            end
            fig = exploreFNIRS.core.plotComposite(obj.groups, panels, varargin{:});
        end


        function result = intraROI(obj, varargin)
        % INTRAROI Within-ROI connectivity analysis per group
        %
        %   result = ex.intraROI()
        %   result = ex.intraROI('Method', 'pearson', 'Biomarker', 'HbO')
        %
        % For each group, computes pairwise coupling between channels within
        % each ROI and summarizes. Requires groupby() and ROI definitions.
        %
        % See also: exploreFNIRS.connectivity.computeIntraROI

            if ~obj.isGrouped
                error('exploreFNIRS:core:Experiment:intraROI', ...
                    'Call groupby() before intraROI()');
            end

            nGroups = length(obj.groups);
            result = struct([]);

            for g = 1:nGroups
                curData = obj.groups(g).gbyFNIRS;
                nSubjects = length(curData);

                fprintf('Group [%d] %s: computing intra-ROI for %d subjects...\n', ...
                    g, obj.groups(g).label, nSubjects);

                subResults = cell(nSubjects, 1);
                useParfor = false;
                if nSubjects > 2
                    [canUse, poolRunning] = pf2_base.accel.canParfor();
                    useParfor = canUse && poolRunning;
                end
                if useParfor
                    parfor s = 1:nSubjects
                        subResults{s} = exploreFNIRS.connectivity.computeIntraROI( ...
                            curData{s}, varargin{:});
                    end
                else
                    for s = 1:nSubjects
                        subResults{s} = exploreFNIRS.connectivity.computeIntraROI( ...
                            curData{s}, varargin{:});
                    end
                end

                result(g).subjectResults = subResults;
                result(g).label = obj.groups(g).label;
                result(g).N = nSubjects;

                % Aggregate across subjects
                nROIs = length(subResults{1}.roiMetrics);
                roiMetrics = subResults{1}.roiMetrics;
                for r = 1:nROIs
                    allMean = zeros(nSubjects, 1);
                    for s = 1:nSubjects
                        allMean(s) = subResults{s}.roiMetrics(r).meanCoupling;
                    end
                    roiMetrics(r).groupMean = mean(allMean, 'omitnan');
                    roiMetrics(r).groupSEM = std(allMean, 'omitnan') / sqrt(nSubjects);
                    roiMetrics(r).groupSD = std(allMean, 'omitnan');
                end
                result(g).roiMetrics = roiMetrics;
                result(g).method = subResults{1}.method;
            end
        end


        function result = interROI(obj, varargin)
        % INTERROI Between-ROI connectivity analysis per group
        %
        %   result = ex.interROI()
        %   result = ex.interROI('Method', 'pearson', 'Biomarker', 'HbO')
        %   result = ex.interROI('Align', 'intersection')
        %
        % For each group, computes connectivity between ROI pairs using
        % ROI-level data. Requires groupby() and ROI definitions.
        %
        % Name-Value Parameters:
        %   Align - Channel alignment mode (default: 'union')
        %
        % See also: exploreFNIRS.connectivity.computeMatrix

            if ~obj.isGrouped
                error('exploreFNIRS:core:Experiment:interROI', ...
                    'Call groupby() before interROI()');
            end

            [align, fwdArgs] = extractAlignArg(varargin);
            result = computeConnectivityGroups(obj.groups, ...
                [{'UseROI', true}, fwdArgs], align);
        end

    end

    methods (Static)

        function ex = fromConfig(cfg)
        % FROMCONFIG Build an Experiment from a declarative config struct
        %
        % Collapses the import -> metadata -> process -> blocks ->
        % Experiment pipeline into a single call. Each config section is
        % optional except one of cfg.import or cfg.data.
        %
        % Syntax:
        %   ex = exploreFNIRS.core.Experiment.fromConfig(cfg)
        %
        % Config Struct Sections:
        %   cfg.import.dir         - Root directory for data files
        %   cfg.import.pattern     - File pattern ('*.snirf', '*.nir', etc.)
        %   cfg.import.dirMapping  - Cell array for importDirectory mapping
        %                            e.g. {'Dir1','Group','Dir2','SubjectID'}
        %
        %   cfg.data               - Pre-loaded cell array (alternative to import)
        %
        %   cfg.metadata.file      - CSV/Excel path for metadata merge
        %   cfg.metadata.key       - Key field(s) for matching
        %
        %   cfg.process.rawMethod  - Named raw processing method
        %   cfg.process.oxyMethod  - Named oxy processing method
        %   cfg.process.options    - Additional NV pairs for processFNIRS2
        %
        %   cfg.blocks.markerCodes - Marker code(s) for defineBlocks
        %   cfg.blocks.duration    - Block duration in seconds
        %   cfg.blocks.conditionMap - Cell array mapping codes to labels
        %   cfg.blocks.preTime     - Time before first marker to keep (default: 5)
        %   cfg.blocks.postTime    - Time after last marker to keep (default: 15)
        %
        %   cfg.experiment.baseline      - [start, end] baseline window
        %   cfg.experiment.taskEnd       - Task end time
        %   cfg.experiment.resampleRate  - Temporal resample rate
        %   cfg.experiment.barBinSize    - Bar chart bin size
        %   cfg.experiment.avgMode       - 'hierarchy', 'flat', or 'none'
        %   cfg.experiment.statWindow    - [start, end] stat analysis window
        %   cfg.experiment.hierarchy     - Cell array of hierarchy levels
        %
        % Example:
        %   cfg.import.dir = 'data/';
        %   cfg.import.pattern = '*.snirf';
        %   cfg.import.dirMapping = {'Dir1','Group','Dir2','SubjectID'};
        %   cfg.metadata.file = 'demographics.csv';
        %   cfg.metadata.key = 'SubjectID';
        %   cfg.blocks.markerCodes = [10, 20];
        %   cfg.blocks.duration = 30;
        %   cfg.blocks.conditionMap = {'Easy','Hard'};
        %   cfg.experiment.baseline = [-5, 0];
        %   cfg.experiment.taskEnd = 30;
        %   cfg.experiment.hierarchy = {'SubjectID','Condition'};
        %
        %   ex = exploreFNIRS.core.Experiment.fromConfig(cfg);
        %   ex.select('Condition', {'Easy','Hard'});
        %   ex.groupby('Condition');
        %   ex.aggregate();
        %
        % See also: exploreFNIRS.core.Experiment, pf2.import.importDirectory,
        %           processFNIRS2, pf2.data.defineBlocks

            % --- Validate ---
            validateConfig(cfg);

            % --- Stage 1: Import ---
            if isfield(cfg, 'data') && ~isempty(cfg.data)
                allData = cfg.data;
                if ~iscell(allData)
                    allData = {allData};
                end
                fprintf('fromConfig: Using %d pre-loaded data segments.\n', length(allData));
            else
                imp = cfg.import;
                dirArgs = {};
                if isfield(imp, 'dirMapping') && ~isempty(imp.dirMapping)
                    dirArgs = imp.dirMapping;
                end
                try
                    allData = pf2.import.importDirectory(imp.dir, imp.pattern, dirArgs{:});
                catch ME
                    error('exploreFNIRS:core:Experiment:fromConfig:importFailed', ...
                        'Import failed: %s', ME.message);
                end
                fprintf('fromConfig: Imported %d files from %s\n', length(allData), imp.dir);
            end

            % --- Stage 2: Metadata ---
            if isfield(cfg, 'metadata') && ~isempty(cfg.metadata)
                meta = cfg.metadata;
                if isfield(meta, 'file') && ~isempty(meta.file)
                    key = 'SubjectID';
                    if isfield(meta, 'key') && ~isempty(meta.key)
                        key = meta.key;
                    end
                    try
                        allData = pf2.data.importInfo(allData, meta.file, key);
                    catch ME
                        error('exploreFNIRS:core:Experiment:fromConfig:metadataFailed', ...
                            'Metadata import failed: %s', ME.message);
                    end
                    fprintf('fromConfig: Merged metadata from %s\n', meta.file);
                end
            end

            % --- Stage 3: Process ---
            if isfield(cfg, 'process') && ~isempty(cfg.process)
                proc = cfg.process;
                rawMethod = '';
                oxyMethod = '';
                procOpts = {};
                if isfield(proc, 'rawMethod'), rawMethod = proc.rawMethod; end
                if isfield(proc, 'oxyMethod'), oxyMethod = proc.oxyMethod; end
                if isfield(proc, 'options'), procOpts = proc.options; end

                procArgs = {};
                if ~isempty(rawMethod) || ~isempty(oxyMethod)
                    procArgs = {rawMethod, oxyMethod};
                end
                try
                    allData = processFNIRS2(allData, procArgs{:}, procOpts{:});
                catch ME
                    error('exploreFNIRS:core:Experiment:fromConfig:processFailed', ...
                        'Processing failed: %s', ME.message);
                end
                fprintf('fromConfig: Processed %d datasets.\n', length(allData));
            end

            % --- Stage 4: Blocks ---
            if isfield(cfg, 'blocks') && ~isempty(cfg.blocks)
                blk = cfg.blocks;
                if ~isfield(blk, 'markerCodes') || isempty(blk.markerCodes)
                    error('exploreFNIRS:core:Experiment:fromConfig:noMarkerCodes', ...
                        'cfg.blocks.markerCodes is required for block extraction.');
                end

                blockArgs = {};
                if isfield(blk, 'conditionMap') && ~isempty(blk.conditionMap)
                    blockArgs = [blockArgs, {'ConditionMap', blk.conditionMap}];
                end
                % Resolve an explicit extraction window. extractBlocks now
                % defaults to a 5 s Buffer (and prints a one-time note) when no
                % window is given; pass PreTime/PostTime explicitly to the
                % extractBlocks call below so this internal path stays silent and
                % reproducible. These are extractBlocks parameters only -- they
                % are NOT appended to blockArgs, which is forwarded to
                % defineBlocks (which does not recognize PreTime/PostTime).
                preTime = 5;
                postTime = 15;
                if isfield(blk, 'preTime') && ~isempty(blk.preTime)
                    preTime = blk.preTime;
                end
                if isfield(blk, 'postTime') && ~isempty(blk.postTime)
                    postTime = blk.postTime;
                end

                dur = 0;
                if isfield(blk, 'duration'), dur = blk.duration; end

                try
                    allData = pf2.data.defineBlocks(allData, blk.markerCodes, dur, ...
                        blockArgs{:}, 'Embed', true);
                    allData = pf2.data.extractBlocks(allData, ...
                        'PreTime', preTime, 'PostTime', postTime);
                catch ME
                    error('exploreFNIRS:core:Experiment:fromConfig:blocksFailed', ...
                        'Block extraction failed: %s', ME.message);
                end
                fprintf('fromConfig: Extracted blocks (%d marker codes, %.0fs duration).\n', ...
                    length(blk.markerCodes), dur);
            end

            % --- Stage 5: Build Experiment ---
            expArgs = {};
            if isfield(cfg, 'experiment') && ~isempty(cfg.experiment)
                expCfg = cfg.experiment;
                if isfield(expCfg, 'hierarchy') && ~isempty(expCfg.hierarchy)
                    expArgs = {'Hierarchy', expCfg.hierarchy};
                end
            end

            ex = exploreFNIRS.core.Experiment(allData, expArgs{:});

            % Apply experiment settings
            if isfield(cfg, 'experiment') && ~isempty(cfg.experiment)
                expCfg = cfg.experiment;
                s = ex.settings;

                if isfield(expCfg, 'baseline'),     s.baseline = expCfg.baseline; end
                if isfield(expCfg, 'taskEnd'),       s.taskEnd = expCfg.taskEnd; end
                if isfield(expCfg, 'resampleRate'),  s.resampleRate = expCfg.resampleRate; end
                if isfield(expCfg, 'barBinSize'),    s.barBinSize = expCfg.barBinSize; end
                if isfield(expCfg, 'avgMode'),       s.avgMode = expCfg.avgMode; end
                if isfield(expCfg, 'statWindow')
                    sw = expCfg.statWindow;
                    if ~isnumeric(sw) || numel(sw) ~= 2
                        error('exploreFNIRS:core:Experiment:fromConfig:invalidStatWindow', ...
                            'statWindow must be a 2-element numeric vector [start, end].');
                    end
                    s.statWindow = sw;
                end
                if isfield(expCfg, 'taskStart'),     s.taskStart = expCfg.taskStart; end

                ex.settings = s;
            end

            fprintf('fromConfig: Experiment created with %d segments.\n', length(allData));
        end

    end

    methods (Hidden)
        % These methods support PlotProxy's transactional state management.
        % They are Hidden so they don't clutter tab-completion, but are
        % accessible from PlotProxy (same package).

        function saveState(obj)
        % SAVESTATE Snapshot lightweight state for later restore
        %
        %   ex.saveState()  % called by PlotProxy before modifying state

            obj.stateSnapshot = struct( ...
                'selectedIdx', obj.selectedIdx, ...
                'groupByVars', {obj.groupByVars}, ...
                'groups', obj.groups, ...
                'isGrouped', obj.isGrouped, ...
                'isAggregated', obj.isAggregated, ...
                'settings', obj.settings);
        end


        function restoreState(obj)
        % RESTORESTATE Restore state from snapshot
        %
        %   ex.restoreState()  % called by PlotProxy after rendering

            if isempty(obj.stateSnapshot), return; end

            s = obj.stateSnapshot;
            obj.selectedIdx = s.selectedIdx;
            obj.groupByVars = s.groupByVars;
            obj.groups = s.groups;
            obj.isGrouped = s.isGrouped;
            obj.isAggregated = s.isAggregated;
            obj.settings = s.settings;
            obj.stateSnapshot = [];
        end


        function narrowSelection(obj, logicalIdx)
        % NARROWSELECTION AND a logical index with current selection
        %
        %   ex.narrowSelection(idx)  % called by PlotProxy for filter

            obj.selectedIdx = obj.selectedIdx & logicalIdx(:);
        end


        function g = getGroups(obj)
        % GETGROUPS Return current groups struct array
            g = obj.groups;
        end


        function tf = getIsAggregated(obj)
        % GETISAGGREGATED Check if experiment is aggregated
            tf = obj.isAggregated;
        end


        function vars = getGroupByVars(obj)
        % GETGROUPBYVARS Return current groupby variable names
            vars = obj.groupByVars;
        end


        function dev = resolveDevice(obj)
        % RESOLVEDEVICE Extract or load Device, propagate to all data
        %
        %   Mirrors the GUI device resolution: first looks for an existing
        %   pf2.Device on any data element, then tries Device.load() from
        %   the first element.  Once resolved, attaches the Device to all
        %   elements that lack one so subsequent calls are instant.

            dev = [];
            if isempty(obj.data), return; end

            % 1. Find first element that already has a Device
            for i = 1:length(obj.data)
                if isfield(obj.data{i}, 'device') ...
                        && isa(obj.data{i}.device, 'pf2.Device')
                    dev = obj.data{i}.device;
                    break;
                end
            end

            % 2. Try loading from first element if none found
            if isempty(dev)
                try
                    dev = pf2.Device.load(obj.data{1});
                catch
                    return;
                end
            end

            % 3. Propagate to all elements that lack one
            for i = 1:length(obj.data)
                if ~isfield(obj.data{i}, 'device') ...
                        || ~isa(obj.data{i}.device, 'pf2.Device')
                    obj.data{i}.device = dev;
                end
            end
        end


        function args = injectColorScheme(obj, args)
        % INJECTCOLORSCHEME Auto-inject colorScheme as Colors if not set
        %
        % Priority: explicit 'ColorScheme' param > explicit 'Colors' > default

            keys = args(1:2:end);

            % Check for explicit 'ColorScheme' param
            csIdx = find(strcmpi(keys, 'ColorScheme'), 1);
            if ~isempty(csIdx)
                valIdx = csIdx * 2;
                csVal = args{valIdx};
                % Resolve name to object
                if ischar(csVal) || isstring(csVal)
                    name = char(csVal);
                    if ~isfield(obj.colorSchemes, name)
                        error('exploreFNIRS:core:Experiment:injectColorScheme', ...
                            'Unknown color scheme: "%s". Available: %s', ...
                            name, strjoin(fieldnames(obj.colorSchemes), ', '));
                    end
                    csVal = obj.colorSchemes.(name);
                end
                % Remove 'ColorScheme' pair, inject as 'Colors'
                args([csIdx * 2 - 1, valIdx]) = [];
                % Only inject if no explicit Colors already
                if ~any(strcmpi(args(1:2:end), 'Colors'))
                    args = [args, {'Colors', csVal}];
                end
                return;
            end

            % Fallback: inject default colorScheme if no Colors set
            if isempty(obj.colorScheme), return; end
            if ~any(strcmpi(keys, 'Colors'))
                args = [args, {'Colors', obj.colorScheme}];
            end
        end


        function args = injectStatWindow(obj, args)
        % INJECTSTATWINDOW Auto-inject statWindow setting as StatWindow param
        %
        % Precedence:
        %   1. User-supplied StatWindow (left untouched)
        %   2. settings.statWindow (when set)
        %   3. [taskStart, taskEnd] when viewPad is set — pins bar stats
        %      so widening the view never silently changes a bar value
            keys = args(1:2:end);
            if any(strcmpi(keys, 'StatWindow')), return; end

            s = obj.settings;
            if ~isempty(s.statWindow)
                args = [args, {'StatWindow', s.statWindow}];
            elseif ~isempty(s.viewPad)
                % Match the exclusive upper bound of trimToTaskWindow
                % (t < tEnd) so the boundary bin at taskEnd — which is
                % a post-task sample — is not included in the bar average.
                if isfinite(s.taskEnd)
                    pinEnd = s.taskEnd - 1e-9;
                else
                    pinEnd = inf;
                end
                args = [args, {'StatWindow', [s.taskStart, pinEnd]}];
            end
        end


        function args = injectTimeModel(obj, args)
        % INJECTTIMEMODEL Auto-inject timeModel/polyOrder settings
            keys = args(1:2:end);
            if ~any(strcmpi(keys, 'TimeModel')) && ~isempty(obj.settings.timeModel)
                args = [args, {'TimeModel', obj.settings.timeModel}];
            end
            if ~any(strcmpi(keys, 'PolynomialOrder')) && obj.settings.polyOrder ~= 2
                args = [args, {'PolynomialOrder', obj.settings.polyOrder}];
            end
        end


        function warnBetweenSubjectConfound(obj, fixedVars, args)
        % WARNBETWEENSUBJECTCONFOUND Flag inestimable between-grouping factors
        %
        % Summary:
        %   When an LME model carries a random grouping variable (e.g. the
        %   (1|SubjectID) random intercept), any fixed-effect factor that is
        %   constant within every level of that grouping variable is
        %   confounded with the random intercept and cannot be estimated. Such
        %   terms produce repeated MATLAB "Hessian not positive definite" /
        %   rank-deficiency warnings and all-NaN ANOVA rows. This helper
        %   detects those factors up front and emits ONE consolidated, plain-
        %   language diagnostic naming the offending factor(s), the grouping
        %   variable, and concrete fixes — so the outcome reads as a design
        %   limitation rather than a toolbox failure.
        %
        % Inputs:
        %   fixedVars - Cell array of candidate fixed-effect variable names
        %               (the current groupby variables).
        %   args      - The varargin name/value cell forwarded to the fit, used
        %               to recover the 'RandomEffects' formula (default
        %               '1|SubjectID').
        %
        % Outputs:
        %   (none) - Emits at most one warning with id
        %            'exploreFNIRS:statsLME:betweenSubjectConfound'.
        %
        % Notes:
        %   - Conservative: only inspects; never alters the user's model.
        %   - Emits a single message per call, not per channel/term.

            % Recover the effective random-effects spec. A CustomFormula
            % overrides RandomEffects entirely, so its grouping structure
            % (not the default '1|SubjectID') is what governs the confound.
            % Default mirrors fitLME.
            randomFx = '1|SubjectID';
            keys = args(1:2:end);
            cfIdx = find(strcmpi(keys, 'CustomFormula'), 1);
            haveCustom = false;
            if ~isempty(cfIdx)
                cfVal = args{cfIdx * 2};
                if (ischar(cfVal) || isstring(cfVal)) && ~isempty(char(cfVal))
                    randomFx = char(cfVal);
                    haveCustom = true;
                end
            end
            if ~haveCustom
                reIdx = find(strcmpi(keys, 'RandomEffects'), 1);
                if ~isempty(reIdx)
                    val = args{reIdx * 2};
                    if ischar(val) || isstring(val)
                        randomFx = char(val);
                    end
                end
            end

            % No '|' anywhere -> no random intercept -> no between-subject
            % confound to flag (e.g. a CustomFormula like 'HbO~Group').
            if ~any(randomFx == '|'), return; end

            % Robustly collect EVERY grouping variable that appears after a
            % '|'. regexp tolerates parentheses, surrounding whitespace, and
            % multiple random terms, e.g. '(1|A)+(1|B)' -> {'A','B'}.
            tok = regexp(randomFx, '\|\s*([A-Za-z]\w*)', 'tokens');
            groupVars = unique(cellfun(@(c) c{1}, tok, 'UniformOutput', false), ...
                'stable');
            if isempty(groupVars), return; end

            % Need the metadata table to test against.
            tbl = obj.getSelectedTable();

            % The confound only BITES when the fitted model carries within-
            % subject replication: a between-subjects factor and (1|grp) are
            % aliased only if grp has more than one observation. With exactly
            % one observation per grouping level the random intercept is
            % confounded with the residual, not with the fixed effect, and the
            % between-subjects term IS estimable (fitlme handles it). Replication
            % enters from two sources: multiple SEGMENTS per level, or multiple
            % TIME BINS per segment (barBinSize>0 over a finite window). Estimate
            % the time-bin count from settings; barBinSize<=0 collapses to a
            % single bar (one time point), so time adds no replication.
            s = obj.settings;
            if isfield(s, 'barBinSize') && s.barBinSize > 0
                ts = 0; if isfield(s, 'taskStart'), ts = s.taskStart; end
                span = NaN;
                if isfield(s, 'taskEnd') && isfinite(s.taskEnd)
                    span = s.taskEnd - ts;
                else
                    % taskEnd = Inf (the default) means "use the full segment".
                    % Derive the span from the actual selected data instead of
                    % assuming infinite replication, otherwise a clean one-
                    % segment-per-subject design with binning enabled is wrongly
                    % flagged. Use the longest selected segment as an upper bound.
                    selData = obj.getSelectedData();
                    maxT = 0;
                    for d = 1:numel(selData)
                        if isstruct(selData{d}) && isfield(selData{d}, 'time') && ...
                                ~isempty(selData{d}.time)
                            maxT = max(maxT, max(selData{d}.time));
                        end
                    end
                    if maxT > ts, span = maxT - ts; end
                end
                if ~isfinite(span) || span <= 0
                    nTimeBins = 1;     % truly unknown window -> assume no time replication
                else
                    nTimeBins = max(1, floor(span / s.barBinSize + 1e-9));
                end
            else
                nTimeBins = 1;         % single bar -> one time point per segment
            end

            % Test each fixed factor against each real grouping column; a
            % factor confounded with ANY grouping variable is flagged, paired
            % with that grouping variable for the message.
            confounded = {};
            confoundGroups = {};
            for g = 1:numel(groupVars)
                groupVar = groupVars{g};
                if ~ismember(groupVar, tbl.Properties.VariableNames), continue; end
                % Skip this grouping variable if the model will have no within-
                % level replication (<=1 segment per level AND <=1 time bin):
                % the between-subjects factor is then estimable, so flagging it
                % would mislead (the reviewer's one-row-per-subject case).
                [~, ~, lvlIdx] = unique(tbl.(groupVar), 'stable');
                maxSegPerLevel = max(accumarray(lvlIdx(:), 1));
                if maxSegPerLevel <= 1 && nTimeBins <= 1, continue; end
                for i = 1:numel(fixedVars)
                    fv = fixedVars{i};
                    if strcmp(fv, groupVar), continue; end
                    if ismember(fv, confounded), continue; end
                    if ~ismember(fv, tbl.Properties.VariableNames), continue; end
                    if exploreFNIRS.core.Experiment.isConstantWithinGroup( ...
                            tbl.(fv), tbl.(groupVar))
                        confounded{end+1} = fv; %#ok<AGROW>
                        confoundGroups{end+1} = groupVar; %#ok<AGROW>
                    end
                end
            end

            if isempty(confounded), return; end

            quoted = cellfun(@(s) ['"' s '"'], confounded, ...
                'UniformOutput', false);
            factorStr = strjoin(quoted, ', ');
            % Name the relevant grouping variable(s) the factors are nested in.
            groupVar = strjoin(unique(confoundGroups, 'stable'), '", "');
            if isscalar(confounded)
                subjVerb = 'is a between-subjects factor';
                pronoun = 'it is';
            else
                subjVerb = 'are between-subjects factors';
                pronoun = 'they are';
            end

            warning('exploreFNIRS:statsLME:betweenSubjectConfound', ...
                ['LME design note: %s %s (constant within every level of the ' ...
                 'random grouping variable "%s"), so %s confounded with the ' ...
                 '(1|%s) random intercept and cannot be estimated — the ' ...
                 'corresponding ANOVA rows will be NaN or unreliable. This ' ...
                 'reflects the design, not a failure: within-subject terms ' ...
                 '(e.g. Condition) still estimate normally. To estimate %s, ' ...
                 'fit a between-subjects model without the (1|%s) random ' ...
                 'intercept (pass ''RandomEffects'' / ''CustomFormula'' ' ...
                 'accordingly), or collapse to one row per %s first (a flat ' ...
                 'avgMode).'], ...
                factorStr, subjVerb, groupVar, pronoun, groupVar, ...
                factorStr, groupVar, groupVar);
        end
    end


    methods (Static, Access = private)
        function cleanupObj = suppressFitWarnings()
        % SUPPRESSFITWARNINGS Scope-suppress fitlme rank/Hessian spam
        %
        % Summary:
        %   Turns off the specific MATLAB LinearMixedModel warning ids that
        %   fitlme repeats per channel/term when a design is rank-deficient or
        %   has more covariance parameters than the data support (the typical
        %   symptom of a between-subjects confound). The previous warning
        %   state is restored automatically when the returned onCleanup object
        %   goes out of scope, so suppression is strictly scoped to the fit and
        %   no unrelated warnings are affected.
        %
        % Outputs:
        %   cleanupObj - onCleanup handle that restores the prior warning state.
        %
        % Notes:
        %   The clean, consolidated explanation comes from
        %   warnBetweenSubjectConfound; this only mutes the raw spam.
        %   Delegates to exploreFNIRS.stats.suppressLMEWarnings so the
        %   suppressed identifier set lives in one place and cannot drift
        %   from the fitLME/fitInfoLME path.
            cleanupObj = exploreFNIRS.stats.suppressLMEWarnings();
        end


        function tf = isConstantWithinGroup(factorCol, groupCol)
        % ISCONSTANTWITHINGROUP True if factorCol is constant within every
        % unique value of groupCol (i.e. the factor is nested in / between
        % the grouping variable). NaN/empty entries are ignored per group.
            tf = false;
            % Coerce both columns to string keys for robust comparison
            fkey = exploreFNIRS.core.Experiment.colToStringKey(factorCol);
            gkey = exploreFNIRS.core.Experiment.colToStringKey(groupCol);
            if numel(fkey) ~= numel(gkey) || isempty(gkey), return; end

            ug = unique(gkey);
            anyValid = false;  % did any group contribute a real (non-missing) value?
            for i = 1:numel(ug)
                sel = strcmp(gkey, ug{i});
                vals = fkey(sel);
                % Ignore missing markers so partially-missing groups don't
                % falsely look variable.
                vals = vals(~strcmp(vals, '<missing>'));
                % A group with no valid values says nothing about constancy;
                % skip it rather than letting its empty set imply "constant".
                if isempty(vals), continue; end
                anyValid = true;
                if numel(unique(vals)) > 1
                    return;  % varies within this group -> not confounded
                end
            end
            % If NO group had a single valid value, there is no evidence the
            % factor is constant -> do not flag it.
            tf = anyValid;
        end


        function keys = colToStringKey(col)
        % COLTOSTRINGKEY Normalize a table column to a cellstr of keys for
        % equality comparison, with a sentinel for missing values.
            if iscell(col)
                keys = cellfun(@(x) localToKey(x), col, 'UniformOutput', false);
            elseif iscategorical(col)
                keys = cellstr(col);
                keys(ismissing(col)) = {'<missing>'};
            elseif isstring(col)
                keys = cellstr(col);
                keys(ismissing(col)) = {'<missing>'};
            elseif isnumeric(col) || islogical(col)
                keys = cell(numel(col), 1);
                for k = 1:numel(col)
                    if isnan(double(col(k)))
                        keys{k} = '<missing>';
                    else
                        % %.15g is precision/locale stable (vs num2str).
                        keys{k} = sprintf('%.15g', double(col(k)));
                    end
                end
            else
                keys = cellstr(string(col));
            end

            function key = localToKey(x)
                if isnumeric(x) || islogical(x)
                    if isempty(x) || any(isnan(double(x(:))))
                        key = '<missing>';
                    else
                        % %.15g is precision/locale stable (vs num2str).
                        key = strjoin(arrayfun(@(v) sprintf('%.15g', v), ...
                            double(x(:)'), 'UniformOutput', false), ' ');
                    end
                elseif ischar(x)
                    if isempty(x), key = '<missing>'; else, key = x; end
                elseif isstring(x)
                    if ismissing(x) || strlength(x) == 0
                        key = '<missing>';
                    else
                        key = char(x);
                    end
                else
                    key = char(string(x));
                end
            end
        end
    end
end


%% Local helper functions

function validateConfig(cfg)
% VALIDATECONFIG Check cfg struct for required fields and valid paths

    errors = {};

    hasImport = isfield(cfg, 'import') && ~isempty(cfg.import);
    hasData = isfield(cfg, 'data') && ~isempty(cfg.data);

    if ~hasImport && ~hasData
        errors{end+1} = 'Either cfg.import or cfg.data is required.';
    end

    if hasImport
        if ~isfield(cfg.import, 'dir') || isempty(cfg.import.dir)
            errors{end+1} = 'cfg.import.dir is required.';
        elseif ~isfolder(cfg.import.dir)
            errors{end+1} = sprintf('cfg.import.dir does not exist: %s', cfg.import.dir);
        end
        if ~isfield(cfg.import, 'pattern') || isempty(cfg.import.pattern)
            errors{end+1} = 'cfg.import.pattern is required (e.g. ''*.snirf'').';
        end
    end

    if isfield(cfg, 'metadata') && ~isempty(cfg.metadata)
        if isfield(cfg.metadata, 'file') && ~isempty(cfg.metadata.file) ...
                && ~isfile(cfg.metadata.file)
            errors{end+1} = sprintf('cfg.metadata.file does not exist: %s', cfg.metadata.file);
        end
    end

    if isfield(cfg, 'blocks') && ~isempty(cfg.blocks)
        if ~isfield(cfg.blocks, 'markerCodes') || isempty(cfg.blocks.markerCodes)
            errors{end+1} = 'cfg.blocks.markerCodes is required when cfg.blocks is set.';
        end
    end

    if ~isempty(errors)
        error('exploreFNIRS:core:Experiment:fromConfig:invalidConfig', ...
            'Config validation failed:\n  - %s', strjoin(errors, '\n  - '));
    end
end


function [ppData, barData] = preprocessGroup(curData, s, doResample, doBaseline)
% PREPROCESSGROUP Preprocess segments: baseline extraction + resampling
%
% Extracted from aggregate() to enable caching.

if doResample || doBaseline
    ppData = cell(size(curData));
    barData = cell(size(curData));

    % Determine effective task end
    if isfinite(s.taskEnd)
        effectiveTaskEnd = s.taskEnd;
    else
        effectiveTaskEnd = max(curData{1}.time);
    end
    taskDuration = effectiveTaskEnd - s.taskStart;
    if taskDuration <= 0
        taskDuration = max(curData{1}.time) - s.taskStart;
    end

    % Determine bar bin size: 0 = full task window (1 bar)
    barBin = s.barBinSize;
    if barBin <= 0
        barBin = taskDuration;
    end

    % View bounds for ppData (display only). When viewPad=[], falls back
    % to the legacy [taskStart, taskEnd) trim. When viewPad is set, the
    % window is widened relative to baseline-start / task-end edges.
    [viewStart, viewEnd, viewActive] = computeViewBounds(s, curData{1});

    % For the non-resample baseline-correction path, the segment is split
    % rather than resampled. Push the lower split bound earlier so that
    % requested pre-baseline samples survive into ppData.
    if doBaseline && viewActive
        splitLow = min(s.baseline(2), viewStart);
    else
        splitLow = [];  % use legacy s.baseline(2)
    end

    for i = 1:length(curData)
        seg = curData{i};

        if doBaseline
            bl = pf2.data.split(seg, s.baseline(1), s.baseline(2));

            if doResample
                ppData{i} = pf2.data.resample(seg, s.resampleRate, ...
                    'centerOnTime', s.taskStart, ...
                    'timeOutMode', 'start', ...
                    'blfNIR', bl, ...
                    'averageAux', true, 'flattenAux', true, 'trimAux', false);
                ppData{i}.time = ppData{i}.time + s.taskStart;

                barData{i} = pf2.data.resample(seg, barBin, ...
                    'centerOnTime', s.taskStart, ...
                    'timeOutMode', 'start', ...
                    'blfNIR', bl, ...
                    'averageAux', true, 'flattenAux', true, 'trimAux', false);
            else
                if isempty(splitLow)
                    ppData{i} = pf2.data.split(seg, s.baseline(2), inf, ...
                        'blfNIR', bl);
                else
                    ppData{i} = pf2.data.split(seg, splitLow, inf, ...
                        'blfNIR', bl);
                end
                % barData stays strictly post-baseline regardless of view
                barData{i} = pf2.data.split(seg, s.baseline(2), inf, ...
                    'blfNIR', bl);
            end
        else
            ppData{i} = pf2.data.resample(seg, s.resampleRate, ...
                'centerOnTime', s.taskStart, ...
                'timeOutMode', 'start', ...
                'averageAux', true, 'flattenAux', true, 'trimAux', false);
            ppData{i}.time = ppData{i}.time + s.taskStart;
            barData{i} = pf2.data.resample(seg, barBin, ...
                'centerOnTime', s.taskStart, ...
                'timeOutMode', 'start', ...
                'averageAux', true, 'flattenAux', true, 'trimAux', false);
        end

        % barData is always trimmed to the strict task window — bar values
        % and downstream stats (LME, exports) must remain pinned regardless
        % of the view setting.
        barData{i} = trimToTaskWindow(barData{i}, 0, taskDuration);

        % ppData uses the view bounds. When viewPad is empty this matches
        % the legacy trim (and is a no-op when taskEnd is Inf).
        if viewActive || isfinite(viewEnd)
            ppData{i} = trimToTaskWindow(ppData{i}, viewStart, viewEnd);
        end
    end
else
    ppData = curData;
    barData = curData;
end

end


function [viewStart, viewEnd, viewActive] = computeViewBounds(s, refSeg)
% COMPUTEVIEWBOUNDS Compute the [start, end] trim window for ppData.
%
% When s.viewPad is empty, returns the legacy task window
% [taskStart, taskEnd). When s.viewPad is set, widens the window relative
% to the baseline-start / task-end edges.
%
% viewActive is true when viewPad is set (signals callers that the
% non-resample split path should also widen its lower bound).

doBaseline = s.useBaseline && ~isempty(s.baseline);

if isempty(s.viewPad)
    viewStart  = s.taskStart;
    if isfinite(s.taskEnd)
        viewEnd = s.taskEnd;
    else
        viewEnd = inf;
    end
    viewActive = false;
    return;
end

pad = s.viewPad;
if isscalar(pad)
    pad = [pad, pad];
elseif numel(pad) ~= 2
    error('exploreFNIRS:core:Experiment:viewPad', ...
        'settings.viewPad must be empty, scalar, or [pre, post]');
end

if doBaseline
    lowerEdge = s.baseline(1);
else
    lowerEdge = s.taskStart;
end

if isfinite(s.taskEnd)
    upperEdge = s.taskEnd;
else
    upperEdge = max(refSeg.time);
end

viewStart  = lowerEdge - pad(1);
viewEnd    = upperEdge + pad(2);
viewActive = true;
end


function barBin = computeBarBin(s, curData)
% COMPUTEBARBIN Compute bar bin size for grandAvgFNIRS
%
% When barBinSize=0 (single bar), each segment has one time point after
% resampling. grandAvgFNIRS cannot auto-detect sample rate from
% single-point data (median(diff([])) = NaN), so we pass it explicitly.

barBin = s.barBinSize;
if barBin <= 0
    if isfinite(s.taskEnd)
        barBin = s.taskEnd - s.taskStart;
    else
        barBin = max(curData{1}.time) - s.taskStart;
    end
    if barBin <= 0
        barBin = max(curData{1}.time);
    end
end

end


function ppKey = buildPPKey(s)
% BUILDPPKEY Build a string key from preprocessing settings for cache lookup
%
% The key encodes settings that affect Stage A (preprocessing). Changing
% any of these values produces a different key, invalidating the cache.

if isempty(s.viewPad)
    vpStr = 'none';
else
    vp = s.viewPad;
    if isscalar(vp), vp = [vp, vp]; end
    vpStr = sprintf('[%.4f,%.4f]', vp(1), vp(2));
end
ppKey = sprintf('bl=[%.4f,%.4f]_rs=%.4f_bb=%.4f_ts=%.4f_te=%.4f_ub=%d_rm=%s_om=%s_vp=%s', ...
    s.baseline(1), s.baseline(2), ...
    s.resampleRate, s.barBinSize, ...
    s.taskStart, s.taskEnd, s.useBaseline, ...
    s.rawMethod, s.oxyMethod, vpStr);

end


function data = trimToTaskWindow(data, tStart, tEnd)
% TRIMTOTASKWINDOW Remove time points outside the task window [tStart, tEnd)

if ~isfield(data, 'time'), return; end
t = data.time;
keep = t >= tStart & t < tEnd;
if all(keep), return; end

nT = length(t);
data.time = t(keep);

% Trim segmentTimes row-wise so [start, mid, end] tuples stay aligned
% with the trimmed time vector. Required for downstream consumers
% (e.g. mergeGbyTablesLong) that index segmentTimes by time row.
if isfield(data, 'segmentTimes') && size(data.segmentTimes, 1) == nT
    data.segmentTimes = data.segmentTimes(keep, :);
end

% Trim biomarker arrays (channel-level)
bioFields = {'HbO','HbR','HbTotal','HbDiff','CBSI','raw','od'};
for f = 1:length(bioFields)
    fn = bioFields{f};
    if isfield(data, fn) && isnumeric(data.(fn)) && size(data.(fn),1) == nT
        data.(fn) = data.(fn)(keep, :);
    end
end

% Trim ROI biomarker arrays so they stay row-aligned with data.time.
% Without this, downstream consumers (grandAvgFNIRS line 400, which
% indexes ROI by the trimmed time's row positions) hit out-of-bounds
% or silently align the wrong samples — producing a non-zero group mean
% in the baseline window even though each segment was baseline-corrected.
if isfield(data, 'ROI') && isstruct(data.ROI)
    roiFields = fieldnames(data.ROI);
    for f = 1:length(roiFields)
        rf = roiFields{f};
        if isnumeric(data.ROI.(rf)) && size(data.ROI.(rf), 1) == nT
            data.ROI.(rf) = data.ROI.(rf)(keep, :);
        end
    end
end

% Trim aux data (tables from flattenAux or structs)
if isfield(data, 'Aux') && isstruct(data.Aux)
    auxFields = fieldnames(data.Aux);
    for f = 1:length(auxFields)
        af = data.Aux.(auxFields{f});
        if istable(af) && height(af) == nT
            data.Aux.(auxFields{f}) = af(keep, :);
        elseif isstruct(af) && isfield(af, 'data') && size(af.data,1) == nT
            data.Aux.(auxFields{f}).data = af.data(keep, :);
            if isfield(af, 'time') && length(af.time) == nT
                data.Aux.(auxFields{f}).time = af.time(keep);
            end
        end
    end
end

end


function hVars = buildHierarchyVars(curTable, validHierarchy, mode)
% Build the hierarchy argument for grandAvgFNIRS based on averaging mode

    switch lower(mode)
        case 'hierarchy'
            tableVars = curTable.Properties.VariableNames;
            useVars = intersect(validHierarchy, tableVars, 'stable');
            if ~isempty(useVars)
                hVars = curTable(:, useVars);
            else
                hVars = (1:size(curTable, 1))';
            end

        case 'flat'
            if ismember('SubjectID', curTable.Properties.VariableNames)
                hVars = curTable(:, 'SubjectID');
            else
                hVars = (1:size(curTable, 1))';
            end

        case 'none'
            hVars = (1:size(curTable, 1))';

        otherwise
            error('exploreFNIRS:core:Experiment:buildHierarchyVars', 'Unknown averaging mode: %s. Use ''hierarchy'', ''flat'', or ''none''.', mode);
    end
end


function [blocks, fwdArgs] = extractBlocksArg(args)
% EXTRACTBLOCKSARG Extract 'Blocks' parameter from name-value argument list
%
% Returns the blocks struct array and the remaining args without 'Blocks'.

blocks = [];
fwdArgs = args;

for k = 1:2:length(args)-1
    if ischar(args{k}) && strcmpi(args{k}, 'Blocks')
        blocks = args{k+1};
        fwdArgs = [args(1:k-1), args(k+2:end)];
        return;
    end
end

end


function [align, fwdArgs] = extractAlignArg(args)
% EXTRACTALIGNARG Extract 'Align' parameter from name-value argument list
%
% Returns the alignment mode and the remaining args without 'Align'.

align = 'union';
fwdArgs = args;

for k = 1:2:length(args)-1
    if ischar(args{k}) && strcmpi(args{k}, 'Align')
        align = args{k+1};
        fwdArgs = [args(1:k-1), args(k+2:end)];
        return;
    end
end

end


function result = computeConnectivityGroups(groups, args, align)
% COMPUTECONNECTIVITYGROUPS Core connectivity computation across groups
%
% Computes per-subject connectivity matrices for each group and aggregates.
% Uses alignMatrices to handle subjects with different valid channels.

if nargin < 3
    align = 'union';
end

nGroups = length(groups);
result = struct([]);

for g = 1:nGroups
    curData = groups(g).gbyFNIRS;
    nSubjects = length(curData);

    fprintf('Group [%d] %s: computing connectivity for %d subjects...\n', ...
        g, groups(g).label, nSubjects);

    subResults = cell(nSubjects, 1);
    useParfor = false;
    if nSubjects > 2
        [canUse, poolRunning] = pf2_base.accel.canParfor();
        useParfor = canUse && poolRunning;
    end
    if useParfor
        parfor s = 1:nSubjects
            subResults{s} = exploreFNIRS.connectivity.computeMatrix(curData{s}, args{:});
        end
    else
        for s = 1:nSubjects
            subResults{s} = exploreFNIRS.connectivity.computeMatrix(curData{s}, args{:});
        end
    end

    % Align and aggregate using channel-identity-aware stacking
    [allMat, masterCh, masterLabels, nValidMat] = ...
        exploreFNIRS.connectivity.alignMatrices(subResults, align);

    result(g).Mean = mean(allMat, 3, 'omitnan');
    result(g).SD = std(allMat, 0, 3, 'omitnan');
    result(g).SEM = result(g).SD ./ sqrt(max(nValidMat, 1));
    result(g).nValid = nValidMat;
    result(g).N = nSubjects;
    result(g).matrices = cellfun(@(r) r.matrix, subResults, 'UniformOutput', false);
    result(g).label = groups(g).label;
    result(g).method = subResults{1}.method;
    result(g).biomarker = subResults{1}.biomarker;
    result(g).channels = masterCh;
    result(g).labels = masterLabels;
    result(g).useROI = subResults{1}.useROI;

    mask = triu(true(size(result(g).Mean)), 1);
    result(g).globalMean = mean(result(g).Mean(mask), 'omitnan');
end

end


function result = computeHyperscanningCore(selData, pairs, groupArgs, nPerms, pThreshold, align)
% COMPUTEHYPERSCANNINGCORE Core hyperscanning computation
%
% Computes group coupling and optional permutation test.

if nargin < 6
    align = 'union';
end

result = exploreFNIRS.hyperscanning.computeGroup(selData, pairs, ...
    'Align', align, groupArgs{:});
result.pairs = pairs;

if nPerms > 0
    fprintf('Running permutation test (%d iterations)...\n', nPerms);
    result.permutation = exploreFNIRS.hyperscanning.permutationTest( ...
        selData, pairs, ...
        'Permutations', nPerms, ...
        'PThreshold', pThreshold, ...
        'Align', align, ...
        groupArgs{:});
end

end


function result = computeHBICAcore(selData, pairs, hbicaArgs, timeWindow)
% COMPUTEHBICACORE Core HB-ICA computation across dyads

nDyads = length(pairs);
dyads = cell(nDyads, 1);
dyadIDs = cell(nDyads, 1);

for d = 1:nDyads
    % pairSubjects emits an .indices vector (not indexA/indexB). HB-ICA is a
    % pairwise decomposition, so require exactly two members per group.
    idx = pairs(d).indices;
    if numel(idx) ~= 2
        if isfield(pairs(d), 'dyadID') && ~isempty(pairs(d).dyadID)
            gid = char(string(pairs(d).dyadID));
        else
            gid = sprintf('group %d', d);
        end
        error('exploreFNIRS:core:Experiment:hbicaNotDyad', ...
            ['HB-ICA operates on dyads, but %s has %d members. Provide ' ...
             '2-member pairs (e.g. ManualPairs {{1,2}}); triad/N-way HB-ICA ' ...
             'is not supported.'], gid, numel(idx));
    end
    idxA = idx(1);
    idxB = idx(2);
    dataA = selData{idxA};
    dataB = selData{idxB};

    args = hbicaArgs;
    if ~isempty(timeWindow)
        args = [args, 'TimeWindow', timeWindow]; %#ok<AGROW>
    end

    dyads{d} = exploreFNIRS.hyperscanning.hbica(dataA, dataB, args{:});

    if isfield(pairs(d), 'dyadID')
        dyadIDs{d} = pairs(d).dyadID;
    else
        dyadIDs{d} = sprintf('Dyad%d', d);
    end
end

% Summary statistics
meanGOF = zeros(nDyads, 1);
nInterBrain = zeros(nDyads, 1);
for d = 1:nDyads
    meanGOF(d) = mean(dyads{d}.GOF);
    nInterBrain(d) = sum(dyads{d}.isInterBrain);
end

result.dyads = dyads;
result.dyadIDs = dyadIDs;
result.pairs = pairs;
result.summary.meanGOF = meanGOF;
result.summary.nInterBrain = nInterBrain;
result.summary.nDyads = nDyads;

end
