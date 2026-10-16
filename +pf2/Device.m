classdef Device
% DEVICE Immutable value class encapsulating fNIRS device configuration
%
% Consolidates device properties (wavelengths, MNI positions, SD distances,
% channel layouts) into a single object with clean accessor methods.
% Replaces scattered access through globals (setF.device, PF2.curWvSet),
% deep struct navigation, and raw .cfg files.
%
% Attach to data structs as data.device for self-describing datasets.
%
% Syntax:
%   dev = pf2.Device.load('fNIR_Devices_fNIR2000')
%   dev = pf2.Device.load(data)
%   dev = pf2.Device.fromProbeInfo(probeInfo, 'myDevice')
%   pf2.Device.clearCache()
%
% Example:
%   data = pf2.import.sampleData.fNIR2000();
%   dev = pf2.Device.load(data);
%   dev.wavelengths()    % [730 850 0 730 850 0 ...]
%   dev.mniPositions()   % [18x3] MNI coordinates
%   dev.hasMNI()         % true
%
% See also: pf2_base.loadDeviceCfg, pf2_base.resolveDeviceFromData

    properties (SetAccess = private)
        name            % Config name, e.g. 'fNIR_Devices_fNIR2000'
        manufacturer    % e.g. 'fNIR Devices'
        model           % e.g. 'Model 2000'
        nChannels       % Measurement channel count
        nShortSep       % Short-separation channel count
        defaultFs       % Default sampling rate (Hz)
        wavelengthSet   % Unique wavelengths in nm, e.g. [730, 850]
        rawMax          % Raw intensity saturation ceiling (device-specific)
        rawMin          % Raw intensity floor (device-specific)
        probeInfo       % Full legacy probeInfo struct (backward compat)
        CoordinateSystem % Coordinate system name (e.g., 'MNI', 'Head', 'MCAspace')
        CoordinateSystemDescription % Detailed description of coordinate system
        CoordinateUnits % Units for coordinates (e.g., 'mm', 'cm', 'm')
        RegistrationMethod % How positions were obtained (e.g., 'template', 'CapTrak-digitized')
        ReferenceHead   % Reference head/template for 3D coords (e.g., 'MNI152', 'unspecified')
        CoordinateProvenance % 'idealized-template' vs 'subject-digitized'
        Landmarks       % Table of landmark positions (e.g., fiducials, 10-20 electrodes)
    end

    methods

        function obj = Device(probeInfo, name, varargin)
        % DEVICE Construct from probeInfo struct and config name
        %
        % Inputs:
        %   probeInfo - Full probeInfo struct with .Info and .Probe{1}
        %   name      - Config name string
        %   varargin  - Optional name-value pairs:
        %               CoordinateSystem - Coordinate system name
        %               CoordinateSystemDescription - System description
        %               CoordinateUnits - Units (mm, cm, m, etc.)
        %               Landmarks - Landmark table

            % Backstop: ensure stats-toolbox fallbacks (nan*) are reachable
            % for any device-building path on a toolbox-less machine.
            pf2_base.ensureStatsFallbacks();

            obj.probeInfo = probeInfo;
            obj.name = name;

            % Extract Info fields with safe fallbacks
            info = probeInfo.Info;
            if isfield(info, 'Manufacturer')
                obj.manufacturer = info.Manufacturer;
            else
                obj.manufacturer = '';
            end
            if isfield(info, 'Name')
                obj.model = info.Name;
            else
                obj.model = '';
            end
            if isfield(info, 'DefaultSamplingRate')
                obj.defaultFs = info.DefaultSamplingRate;
            else
                obj.defaultFs = NaN;
            end

            % Channel counts from first probe
            probe = probeInfo.Probe{1};
            obj.nChannels = probe.NumOptodes;
            if isfield(probe, 'NumShortSeparation')
                obj.nShortSep = probe.NumShortSeparation;
            else
                obj.nShortSep = 0;
            end

            % Unique wavelengths (excluding 0/NaN/dark)
            wl = probe.TableCh.Wavelength(:)';
            validWl = wl(wl > 0 & ~isnan(wl));
            obj.wavelengthSet = unique(validWl);

            % Raw intensity bounds (saturation detection)
            if isfield(info, 'RawMax')
                obj.rawMax = info.RawMax;
            else
                obj.rawMax = NaN;
            end
            if isfield(info, 'RawMin')
                obj.rawMin = info.RawMin;
            else
                obj.rawMin = NaN;
            end

            % Parse optional coordinate system and landmarks. Defaults are
            % drawn from probeInfo.Info (the .cfg path declares them there);
            % name-value pairs override (the in-memory import path passes them
            % explicitly, e.g. CapTrak coords from SNIRF).
            p = inputParser;
            addParameter(p, 'CoordinateSystem', iInfoStr(info, 'CoordinateSystem'), @ischar);
            addParameter(p, 'CoordinateSystemDescription', iInfoStr(info, 'CoordinateSystemDescription'), @ischar);
            addParameter(p, 'CoordinateUnits', iInfoStr(info, 'CoordinateUnits'), @ischar);
            addParameter(p, 'RegistrationMethod', iInfoStr(info, 'RegistrationMethod'), @ischar);
            addParameter(p, 'ReferenceHead', iInfoStr(info, 'ReferenceHead'), @ischar);
            addParameter(p, 'CoordinateProvenance', iInfoStr(info, 'CoordinateProvenance'), @ischar);
            addParameter(p, 'Landmarks', [], @(x) istable(x) || isempty(x));
            parse(p, varargin{:});

            obj.CoordinateSystem = p.Results.CoordinateSystem;
            obj.CoordinateSystemDescription = p.Results.CoordinateSystemDescription;
            obj.CoordinateUnits = p.Results.CoordinateUnits;
            obj.RegistrationMethod = p.Results.RegistrationMethod;
            obj.ReferenceHead = p.Results.ReferenceHead;
            obj.CoordinateProvenance = p.Results.CoordinateProvenance;
            obj.Landmarks = p.Results.Landmarks;
        end

        %% Accessor methods

        function wl = wavelengths(obj)
        % WAVELENGTHS Wavelength per raw column [1 x C_raw]
            wl = obj.probeInfo.Probe{1}.TableCh.Wavelength(:)';
        end

        function ch = channelNumbers(obj)
        % CHANNELNUMBERS Optode number per raw column [1 x C_raw]
            ch = obj.probeInfo.Probe{1}.TableCh.OptodeNumber(:)';
        end

        function cl = channelList(obj)
        % CHANNELLIST Unique channel indices [1 x nCh]
            cl = obj.probeInfo.Probe{1}.TableOpt.OptodeNum(:)';
        end

        function pos = mniPositions(obj)
        % MNIPOSITIONS MNI coordinates [nCh x 3]
        %
        % Returns empty [] if no 3D positions are available.
            tbl = obj.probeInfo.Probe{1}.TableOpt;
            if all(ismember({'Pos3D_x','Pos3D_y','Pos3D_z'}, tbl.Properties.VariableNames))
                pos = [tbl.Pos3D_x, tbl.Pos3D_y, tbl.Pos3D_z];
            else
                pos = [];
            end
        end

        function sd = sdDistances(obj)
        % SDDISTANCES Source-detector distances [1 x nCh]
            sd = obj.probeInfo.Probe{1}.TableOpt.SD(:)';
        end

        function tbl = channelTable(obj)
        % CHANNELTABLE Full channel table (TableCh)
            tbl = obj.probeInfo.Probe{1}.TableCh;
        end

        function tbl = optodeTable(obj)
        % OPTODETABLE Full optode table (TableOpt)
            tbl = obj.probeInfo.Probe{1}.TableOpt;
        end

        function lay = layout2D(obj)
        % LAYOUT2D Cell array of subplot positions (standard channels only)
            if isfield(obj.probeInfo.Probe{1}, 'OptPos') && ...
                    ismember('subplot_layout', obj.probeInfo.Probe{1}.OptPos.Properties.VariableNames)
                lay = obj.probeInfo.Probe{1}.OptPos.subplot_layout;
            else
                lay = {};
            end
        end

        function lay = layout2Dss(obj)
        % LAYOUT2DSS Cell array of subplot positions including short-separation
        %
        % Returns subplot_layout_ss if available, which includes positions
        % for both standard and short-separation channels. Falls back to
        % layout2D() if the _ss variant is not present.
            if isfield(obj.probeInfo.Probe{1}, 'OptPos') && ...
                    istable(obj.probeInfo.Probe{1}.OptPos) && ...
                    ismember('subplot_layout_ss', obj.probeInfo.Probe{1}.OptPos.Properties.VariableNames)
                lay = obj.probeInfo.Probe{1}.OptPos.subplot_layout_ss;
            else
                lay = obj.layout2D();
            end
        end

        function lay = layoutSchematic(obj)
        % LAYOUTSCHEMATIC Clean flat "schematic" grid layout (standard channels)
        %
        % Tidy grid montage for explanatory 2D plotting, independent of the
        % affine 3D->2D projection returned by layout2D(). Falls back to
        % layout2D() if no schematic layout is present.
            P = obj.probeInfo.Probe{1};
            if isfield(P, 'OptPos') && istable(P.OptPos) && ...
                    ismember('subplot_layout_schematic', P.OptPos.Properties.VariableNames)
                lay = P.OptPos.subplot_layout_schematic;
            else
                lay = obj.layout2D();
            end
        end

        function tf = hasDeclaredLayout(obj)
        % HASDECLAREDLAYOUT True if the device declares an explicit flat montage
        %
        % True when the .cfg supplies LayoutRows/LayoutCols or Layout2D_x/y.
        % False when the schematic layout is only an auto-generated grid.
            P = obj.probeInfo.Probe{1};
            tf = isfield(P, 'LayoutDeclared') && logical(P.LayoutDeclared);
        end

        function tf = hasGeometry(obj)
        % HASGEOMETRY True if the device has physical optode coordinates
        %
        % False for "layout-only" devices that carry only a schematic grid for
        % plotting (no 2D/3D optode positions). Use this to gate code that
        % needs real geometry (3D rendering, atlas lookup, SNIRF geometry).
            if obj.hasMNI()
                tf = true;
                return;
            end
            tbl = obj.probeInfo.Probe{1}.TableOpt;
            tf = all(ismember({'Pos2D_x','Pos2D_y'}, tbl.Properties.VariableNames)) ...
                && ~isempty(tbl.Pos2D_x) && any(~isnan(tbl.Pos2D_x));
        end

        function tf = hasMNI(obj)
        % HASMNI True if 3D MNI positions are available
            tbl = obj.probeInfo.Probe{1}.TableOpt;
            tf = all(ismember({'Pos3D_x','Pos3D_y','Pos3D_z'}, tbl.Properties.VariableNames)) ...
                && ~isempty(tbl.Pos3D_x) && any(~isnan(tbl.Pos3D_x) & tbl.Pos3D_x ~= 0);
        end

        function tf = isShortSep(obj)
        % ISSHORTSEP Logical mask for short-separation channels [1 x nCh]
            tf = obj.probeInfo.Probe{1}.TableOpt.IsShortSeparation(:)';
        end

        function [pos, labels] = sourcePositions(obj)
        % SOURCEPOSITIONS Source optode MNI coordinates [nSrc x 3]
        %
        % Positions are returned as stored (MNI for MNI-registered montages),
        % mirroring mniPositions(); no coordinate transform is applied. Returns
        % empty [] if per-optode source/detector 3D positions are unavailable.
        % Optional second output returns the source labels [nSrc x 1] string.
            [pos, labels] = obj.sdTypePositions('Src');
        end

        function [pos, labels] = detectorPositions(obj)
        % DETECTORPOSITIONS Detector optode MNI coordinates [nDet x 3]
        %
        % See sourcePositions() for the coordinate-frame caveat. Returns empty
        % [] if positions are unavailable; optional second output is the
        % detector labels [nDet x 1] string.
            [pos, labels] = obj.sdTypePositions('Det');
        end

        function tf = hasSDPositions(obj)
        % HASSDPOSITIONS True if per-optode source/detector 3D positions exist
            tf = ~isempty(obj.sdTypePositions('Src')) || ...
                 ~isempty(obj.sdTypePositions('Det'));
        end

    end

    methods (Access = private)

        function [pos, labels] = sdTypePositions(obj, which)
        % SDTYPEPOSITIONS Positions/labels of one optode type from TableSD
        %
        % Inputs:
        %   which - 'Src' selects sources; any other value selects detectors.
        % Outputs:
        %   pos    - [n x 3] Pos3D for the selected type ([] if unavailable).
        %   labels - [n x 1] string labels ([] when pos is []).
            pos = []; labels = strings(0, 1);
            probe = obj.probeInfo.Probe{1};
            if ~isfield(probe, 'TableSD'), return; end
            tbl = probe.TableSD;
            if ~istable(tbl) || ~all(ismember({'Pos3D_x', 'Pos3D_y', 'Pos3D_z', 'Type'}, ...
                    tbl.Properties.VariableNames))
                return;
            end
            isSrc = (tbl.Type == 'Src');
            if strcmpi(which, 'Src'), sel = isSrc; else, sel = ~isSrc; end
            p = [tbl.Pos3D_x(sel), tbl.Pos3D_y(sel), tbl.Pos3D_z(sel)];
            if isempty(p) || all(p(:) == 0) || all(isnan(p(:)))
                return;
            end
            pos = p;
            if ismember('Label', tbl.Properties.VariableNames)
                labels = string(tbl.Label(sel));
            else
                labels = strings(size(p, 1), 1);
            end
        end

    end

    methods (Static)

        function dev = load(nameOrData)
        % LOAD Create Device from config name or data struct (cached)
        %
        % Syntax:
        %   dev = pf2.Device.load('fNIR_Devices_fNIR2000')
        %   dev = pf2.Device.load(data)
        %
        % Inputs:
        %   nameOrData - Config name string (without .cfg extension),
        %                OR fNIRS data struct with info.probename field

            persistent cache
            if isempty(cache)
                cache = containers.Map('KeyType', 'char', 'ValueType', 'any');
            end

            % Handle cache clear sentinel
            if ischar(nameOrData) && strcmp(nameOrData, '__clear__')
                cache = containers.Map('KeyType', 'char', 'ValueType', 'any');
                dev = [];
                return;
            end

            % Under GNU Octave, load packages and shims (no-op in MATLAB)
            pf2_base.env.ensureOctaveCompat();

            % Resolve config name from data struct
            if isstruct(nameOrData)
                if isfield(nameOrData, 'info') && isfield(nameOrData.info, 'probename')
                    cfgName = nameOrData.info.probename;
                else
                    error('pf2:Device:load:noProbename', ...
                        'Data struct must have info.probename field.');
                end
            elseif ischar(nameOrData) || isstring(nameOrData)
                cfgName = char(nameOrData);
                % Strip .cfg extension if present
                cfgName = regexprep(cfgName, '\.cfg$', '');
            else
                error('pf2:Device:load:badInput', ...
                    'Input must be a config name string or fNIRS data struct.');
            end

            % Check for unknown/invalid probe names
            if contains(cfgName, 'Unknown') || contains(cfgName, 'Unkown')
                error('pf2:Device:load:unknownProbe', ...
                    'Cannot load Device for unknown probe: %s', cfgName);
            end

            % Return from cache if available
            if cache.isKey(cfgName)
                dev = cache(cfgName);
                return;
            end

            % Load from .cfg file (no global side-effects)
            probeInfo = pf2_base.loadDeviceCfg(cfgName, true, false);

            dev = pf2.Device(probeInfo, cfgName);
            cache(cfgName) = dev;
        end

        function dev = fromProbeInfo(probeInfo, name, varargin)
        % FROMPROBEINFO Create Device from an already-loaded probeInfo struct
        %
        % For SNIRF/NIRX imports where probeInfo is built in-memory.
        %
        % Syntax:
        %   dev = pf2.Device.fromProbeInfo(probeInfo, 'myDevice')
        %   dev = pf2.Device.fromProbeInfo(probeInfo)
        %   dev = pf2.Device.fromProbeInfo(probeInfo, name, 'CoordinateSystem', 'MNI', 'Landmarks', tbl)
        %
        % Inputs:
        %   probeInfo - Full probeInfo struct with .Info and .Probe{1}
        %   name      - Optional config name (default: from Info.CfgName)
        %   varargin  - Optional name-value pairs for CoordinateSystem, etc.

            if nargin < 2 || isempty(name)
                if isfield(probeInfo, 'Info') && isfield(probeInfo.Info, 'CfgName')
                    name = probeInfo.Info.CfgName;
                else
                    name = 'custom';
                end
            end
            dev = pf2.Device(probeInfo, name, varargin{:});
        end

        function clearCache()
        % CLEARCACHE Reset the persistent Device cache
        %
        % Useful for testing or after device config files change.
            pf2.Device.load('__clear__');
        end

    end

end

function v = iInfoStr(info, field)
% IINFOSTR Safely read a string field from probeInfo.Info ('' if absent)
    if isstruct(info) && isfield(info, field) ...
            && (ischar(info.(field)) || isstring(info.(field))) ...
            && ~isempty(info.(field))
        v = char(info.(field));
    else
        v = '';
    end
end
