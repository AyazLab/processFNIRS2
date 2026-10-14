classdef GUIContext < pf2_base.ProcessingContext
    % GUICONTEXT Extends ProcessingContext with GUI-specific state
    %
    % GUIContext adds view settings, stage data, and selection state needed
    % by the processFNIRS2 GUI while inheriting all processing settings from
    % ProcessingContext.
    %
    % This class enables the GUI to use a single context object instead of
    % multiple global variables, improving testability and maintainability.
    %
    % Syntax:
    %   ctx = GUIContext()                    % Create with defaults
    %   ctx = GUIContext.fromGlobals()        % Create from current global state
    %
    % Properties (inherited from ProcessingContext):
    %   dpfMode, dpfFixedValue, subjectAge    - DPF settings
    %   baselineStartTime, baselineLength     - Baseline settings
    %   rawMethod, oxyMethod                  - Processing methods
    %   device                                - Device configuration
    %   rejectLevel, processRejected          - Quality control
    %
    % Properties (GUI-specific):
    %   view          - View/display settings (time window, y-limits, etc.)
    %   stages        - Processing stage data {raw, processedRaw, OD, Hb, filteredHb}
    %   data          - Current fNIRS data structure
    %   selectedChannels, selectedWavelengths - Current selections
    %   processWindowOnly - Process only visible time window
    %
    % Example:
    %   % Create GUI context
    %   ctx = pf2_base.GUIContext();
    %   ctx.view.startTime = 0;
    %   ctx.view.endTime = 100;
    %   ctx.dpfMode = 'Calc';
    %
    % See also: pf2_base.ProcessingContext, processFNIRS2_GUI

    properties
        % View settings (time window, y-axis limits, display options)
        view struct = struct(...
            'startTime', 0, ...
            'endTime', 100, ...
            'LightAuto', true, ...
            'OxyAuto', true, ...
            'LightMin', 0, ...
            'LightMax', 4096, ...
            'OxyMin', -5, ...
            'OxyMax', 5, ...
            'plotOD', false, ...
            'LightColorAuto', true, ...
            'OxyColorAuto', true)

        % Processing stage data
        % {1: raw, 2: processedRaw, 3: OD, 4: Hb, 5: filteredHb}
        stages cell = cell(1, 5)

        % Current fNIRS data (time, markers, info, etc.)
        data struct = struct()

        % Current selections for display
        selectedChannelIndices double = []
        selectedWavelengths double = []
        selectedBiomarkers double = []  % indices into biomarker list
        selectedMarkers double = []

        % Optode table for GUI display
        optodeTable = []

        % Processing options
        processWindowOnly (1,1) logical = false

        % Figure and axes handles
        figHandle = []
        axesHandles cell = {}
    end

    methods
        function obj = GUIContext(varargin)
            % GUICONTEXT Create a new GUI context with defaults
            % Any input (copy() passes COPY_TOKEN) is ignored.
            obj@pf2_base.ProcessingContext();
        end

        function setViewWindow(obj, startTime, endTime)
            % SETVIEWWINDOW Set the visible time window
            %
            % Syntax:
            %   ctx.setViewWindow(0, 60)  % View t=0 to t=60
            obj.view.startTime = startTime;
            obj.view.endTime = endTime;
        end

        function [timeInd, startIdx, endIdx] = getViewIndices(obj)
            % GETVIEWINDICES Get indices for current view window
            %
            % Returns logical and numeric indices into the time vector
            % for the current view window settings.
            %
            % Syntax:
            %   [timeInd, startIdx, endIdx] = ctx.getViewIndices()

            if isfield(obj.data, 'time') && ~isempty(obj.data.time)
                [timeInd, startIdx, endIdx] = pf2_base.gui.getTimeIndices(...
                    obj.data.time, obj.view.startTime, obj.view.endTime);
            else
                timeInd = [];
                startIdx = 1;
                endIdx = 1;
            end
        end

        function croppedData = getCroppedData(obj, stageNum)
            % GETCROPPEDDATA Get stage data cropped to current view window
            %
            % Syntax:
            %   data = ctx.getCroppedData(4)  % Get cropped Hb data

            if nargin < 2
                stageNum = 5;  % Default to filtered Hb
            end

            stageData = obj.stages{stageNum};
            if isempty(stageData)
                croppedData = [];
                return;
            end

            % Build temporary struct for cropping
            if isstruct(stageData)
                tempData = stageData;
            else
                tempData = struct('raw', stageData);
            end

            if ~isfield(tempData, 'time')
                tempData.time = obj.data.time;
            end

            croppedData = pf2.data.crop(tempData, obj.view.startTime, obj.view.endTime);
        end

        function syncFromGlobals(obj)
            % SYNCFROMGLOBALS Pull current values from PF2/setF globals
            %
            % Reads the current global state and updates this context.
            % Useful for initializing the context from existing GUI state.

            global PF2 setF

            % Call parent method for processing settings
            parentCtx = pf2_base.ProcessingContext.fromGlobals();
            obj.dpfMode = parentCtx.dpfMode;
            obj.dpfFixedValue = parentCtx.dpfFixedValue;
            obj.pvc = parentCtx.pvc;
            obj.ppf = parentCtx.ppf;
            obj.subjectAge = parentCtx.subjectAge;
            obj.baselineStartTime = parentCtx.baselineStartTime;
            obj.baselineLength = parentCtx.baselineLength;
            obj.rawMethod = parentCtx.rawMethod;
            obj.rawMethodName = parentCtx.rawMethodName;
            obj.oxyMethod = parentCtx.oxyMethod;
            obj.oxyMethodName = parentCtx.oxyMethodName;
            obj.rawMethodsLib = parentCtx.rawMethodsLib;
            obj.oxyMethodsLib = parentCtx.oxyMethodsLib;
            obj.device = parentCtx.device;
            obj.rejectLevel = parentCtx.rejectLevel;

            % Sync GUI-specific state from PF2.GUIPF2 if it exists
            if pf2_base.isnestedfield(PF2, 'GUIPF2.view')
                obj.view = PF2.GUIPF2.view;
            end

            if pf2_base.isnestedfield(PF2, 'GUIPF2.data')
                obj.data = PF2.GUIPF2.data;
                if isfield(PF2.GUIPF2.data, 'stage')
                    obj.stages = PF2.GUIPF2.data.stage;
                end
            end

            if pf2_base.isnestedfield(PF2, 'GUIPF2.processWindowOnly')
                obj.processWindowOnly = PF2.GUIPF2.processWindowOnly;
            end

            if pf2_base.isnestedfield(PF2, 'GUIPF2.optodeTable')
                obj.optodeTable = PF2.GUIPF2.optodeTable;
            end
        end

        function syncToGlobals(obj)
            % SYNCTOGLOBALS Push context values back to global variables
            %
            % Updates PF2 and setF globals from this context.
            % Needed for backward compatibility with code that reads globals.

            global PF2 setF

            % Ensure initialized
            if ~isfield(PF2, 'myRawMethods')
                pf2_base.pf2_initialize();
            end

            % Push processing settings back to the globals the GUI reads.
            % (This globals-write path is intentionally GUI-only: the general
            % ProcessingContext is one-directional and never writes globals.)
            PF2.dpf_mode = obj.dpfMode;
            PF2.curDPF_fixed = obj.dpfFixedValue;
            PF2.pvc = obj.pvc;
            PF2.ppf = obj.ppf;
            PF2.curDPF_age = obj.subjectAge;

            PF2.baseline.startTime = obj.baselineStartTime;
            PF2.baseline.blLength = obj.baselineLength;
            PF2.baseline.useAbsoluteTime = obj.useAbsoluteTime;
            PF2.baseline.windowStartTime = obj.windowStartTime;

            PF2.RejectLevel = obj.rejectLevel;
            PF2.OutputLegacyMarkers = obj.outputLegacyMarkers;

            if ~isempty(obj.rawMethod) && isfield(obj.rawMethod, 'name')
                PF2.stageRawMethod = obj.rawMethod;
            end
            if ~isempty(obj.oxyMethod) && isfield(obj.oxyMethod, 'name')
                PF2.stageOxyMethod = obj.oxyMethod;
            end

            if ~isempty(fieldnames(obj.device))
                setF.device = obj.device;
            end

            % Sync GUI-specific state to PF2.GUIPF2
            if ~isfield(PF2, 'GUIPF2')
                PF2.GUIPF2 = struct();
            end

            PF2.GUIPF2.view = obj.view;
            PF2.GUIPF2.processWindowOnly = obj.processWindowOnly;
            PF2.GUIPF2.optodeTable = obj.optodeTable;

            % Sync DPF values to GUI-specific fields
            PF2.GUIPF2.dpf_mode = obj.dpfMode;
            PF2.GUIPF2.curDPF_fixed = obj.dpfFixedValue;
            PF2.GUIPF2.pvc = obj.pvc;
            if isempty(obj.ppf); PF2.GUIPF2.ppf = 6; else; PF2.GUIPF2.ppf = obj.ppf; end
            PF2.GUIPF2.curDPF_age = obj.subjectAge;

            % Sync baseline
            PF2.GUIPF2.baseline.startTime = obj.baselineStartTime;
            PF2.GUIPF2.baseline.blLength = obj.baselineLength;

            % Sync methods
            PF2.GUIPF2.stageRawMethod = obj.rawMethod;
            PF2.GUIPF2.stageOxyMethod = obj.oxyMethod;
        end

        function baseline = getBaselineStruct(obj)
            % GETBASELINESTRUCT Get baseline settings as struct for processing
            %
            % Returns a struct compatible with processStageOD2Hb
            baseline = struct(...
                'startTime', obj.baselineStartTime, ...
                'blLength', obj.baselineLength);
        end
    end

    methods (Static)
        function obj = fromGlobals()
            % FROMGLOBALS Create a GUIContext from current global state
            %
            % Syntax:
            %   ctx = pf2_base.GUIContext.fromGlobals();

            obj = pf2_base.GUIContext();
            obj.syncFromGlobals();
        end
    end
end
