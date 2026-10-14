function probeInfo=loadDeviceCfg(deviceCfgFilename,includeSSchannels,loadFromGlobal)
% LOADDEVICECFG Load and parse fNIRS device configuration file
%
% Reads a device configuration file (.cfg) and constructs a comprehensive
% probeInfo structure containing channel mappings, optode positions (2D and
% 3D), source-detector separation distances, wavelength information, and
% probe layout data for visualization.
%
% The function supports caching via a global deviceTable to avoid reloading
% previously parsed configurations.
%
% Syntax:
%   probeInfo = loadDeviceCfg()
%   probeInfo = loadDeviceCfg(deviceCfgFilename)
%   probeInfo = loadDeviceCfg(deviceCfgFilename, includeSSchannels)
%   probeInfo = loadDeviceCfg(deviceCfgFilename, includeSSchannels, loadFromGlobal)
%   loadDeviceCfg(deviceCfgFilename)  % Assigns to global setF
%
% Inputs:
%   deviceCfgFilename - Path to device configuration file (string)
%                       If empty, opens file selection dialog.
%                       Can be filename only (searches /devices folder) or
%                       full path. Extension .cfg is added if missing.
%   includeSSchannels - Include short separation channels in 2D layouts
%                       (default: true). Set false to exclude SS channels
%                       from visualization layouts.
%   loadFromGlobal    - Load from cached deviceTable if available
%                       (default: true). Set false to force reload.
%
% Outputs:
%   probeInfo - Device configuration structure with fields:
%               .cfg      - Raw INI configuration object
%               .Info     - Device metadata (name, manufacturer, etc.)
%               .Probe{i} - Cell array of probe structures, each containing:
%                   .NumOptodes        - Number of measurement channels
%                   .NumShortSeparation - Number of short separation channels
%                   .TableOpt          - Table of optode properties
%                   .TableSD           - Table of source/detector properties
%                   .TableCh           - Table of raw channel mappings
%                   .SrcPos, .DetPos, .OptPos - Position tables (2D and 3D)
%
%   When called with no output arguments, assigns probeInfo to global setF
%   and updates the global deviceTable cache.
%
% Supported Device Configurations:
%   - fNIR Devices (fNIR1000, fNIR2000, etc.)
%   - Hitachi ETG-4000 (3x5, 3x11 configurations)
%   - NIRx Sport systems
%   - Custom probe configurations
%
% Example:
%   % Load fNIR 2000 configuration
%   probe = loadDeviceCfg('fNIR_Devices_fNIR2000');
%   disp(probe.Probe{1}.NumOptodes);
%
%   % Load with file dialog
%   probe = loadDeviceCfg();
%
%   % Assign to global and cache
%   loadDeviceCfg('fNIR_Devices_fNIR2000');
%   global setF
%   disp(setF.device.Info.Name);
%
% See also: buildProbeLayout, loadProbeInfo, pf2.settings.selectDevice,
%           fitProbe2D, pf2_initialize

% Ensure stats-toolbox fallbacks (nansum/nanmean/...) are reachable when
% importing on a toolbox-less machine before pf2_initialize has run.
pf2_base.ensureStatsFallbacks();

% Set default values for input arguments
if nargin < 1
    deviceCfgFilename = '';
end
if nargin < 2
    includeSSchannels = true;
end

if(nargin<3)
    loadFromGlobal=true;
end

% Get the default root path
pF2_folder = pf2_base.pf2_defaultRootPath();

% Try to load the device configuration file
[probeInfo, name] = loadDeviceConfig(deviceCfgFilename, pF2_folder);

% Check if the probe is already in the global deviceTable
global deviceTable

forceLoad = isempty(deviceCfgFilename)>0;

if ~forceLoad&&~isempty(deviceTable) && any(strcmp(name, deviceTable.Probe)) && loadFromGlobal
    global setF
    setF = deviceTable.ProbeInfo(strcmp(name, deviceTable.Probe));
    probeInfo = setF.device;
    return;
end

% Read the configuration file
probeInfo.cfg.read();
probeInfo.Info = probeInfo.cfg.Info;

probeInfo = processProbeInfo(probeInfo, includeSSchannels);
    


if(nargout==0) % assigns the global device
    global setF
    if(isempty(deviceTable))
        deviceTable = cell2table(cell(0, 2), 'VariableNames', {'Probe', 'ProbeInfo'});
    end
    container = {};
    container.device = probeInfo;
    existingDevice = strcmp(deviceTable.Probe,name);
    deviceTable(existingDevice,:)=[];
    deviceTable = [deviceTable; cell2table({name, container}, 'VariableNames', {'Probe', 'ProbeInfo'})];
    setF.device=probeInfo;
end

end

function opt_2d_coords=setUpFalse2D(numCh)

    for i=1:numCh
        x1=i-1;
        x2=1;
        y1=0;
        y2=0.9;
        x2=x2/numCh;
        x1=x1/numCh;

        opt_2d_coords{i}=[x1,y1,x2,y2];
    end
end

function [proj2d,n,V,p] = affine_fit(XYZ)
    %Computes the plane that fits best (lest square of the normal distance
    %to the plane) a set of sample points.
    %INPUTS:
    %
    %X: a N by 3 matrix where each line is a sample point
    %
    %OUTPUTS:
    %
    %n : a unit (column) vector normal to the plane
    %V : a 3 by 2 matrix. The columns of V form an orthonormal basis of the
    %plane
    %p : a point belonging to the plane
    %
    %NB: this code actually works in any dimension (2,3,4,...)
    %Author: Adrien Leygue
    %Date: August 30 2013
    
    %the mean of the samples belongs to the plane
    p = mean(XYZ,1);
    
    %The samples are reduced:
    R = bsxfun(@minus,XYZ,p);
    %Computation of the principal directions if the samples cloud
    [V,D] = eig(R'*R);
    %Extract the output from the eigenvectors
    n = V(:,1);
    V = V(:,2:end);
    
    proj2d=project(XYZ,n,V,p);
end

function proj2d=project(XYZ,n,V,p)

    XYZ_p=XYZ-p; %move points onto plane
    
    A=[1 0 0 -n(1); 0 1 0 -n(2); 0 0 1 -n(3); n' 0];
    
    B=(A\[XYZ_p';zeros(size(XYZ(:,1)'))])';
    
    r=pf2_base.external.vrrotvec([0,0,1],n);
    RM=pf2_base.external.vrrotvec2mat(r);
    
    proj2d=B(:,1:3)*RM;
   

end



function [probeInfo, name] = loadDeviceConfig(deviceCfgFilename, pF2_folder)
    if isempty(deviceCfgFilename)
        [file, pathname] = uigetfile({'*.cfg;*.ini', 'Configuration Files (*.cfg, *.ini)'; ...
                                      '*.*', 'All Files (*.*)'}, ...
                                     'Select Device Configuration File', ...
                                     fullfile(pF2_folder, 'devices'));
        if isequal(file, 0)
            error('pf2_base:loadDeviceCfg:userCancelled', 'User cancelled file selection');
        end
        deviceCfgFilename = fullfile(pathname, file);
    elseif(~contains(lower(deviceCfgFilename),'.cfg'))
        deviceCfgFilename=strcat(deviceCfgFilename,'.cfg');
    end

    [~, name, ~] = fileparts(deviceCfgFilename);

    % Try to open the file
    if ~exist(deviceCfgFilename, 'file')
        % If not found, try in the devices folder
        altPath = fullfile(pF2_folder, 'devices', deviceCfgFilename);
        if exist(altPath, 'file')
            deviceCfgFilename = altPath;
        else
            error('pf2_base:loadDeviceCfg:fileNotFound', 'Configuration file not found: %s', deviceCfgFilename);
        end
    end

    % Load the configuration file
    try
        probeInfo.cfg = pf2_base.external.INI('File', deviceCfgFilename);
    catch ME
        error('pf2_base:loadDeviceCfg:loadFailed', 'Error loading configuration file: %s', ME.message);
    end
end

function probeInfo = processProbeInfo(probeInfo, includeSSchannels)
    % Declared 3D coordinate units + a device label, for the unit-aware
    % 2D-from-3D fallback in processPositionInfo.
    coordUnits = '';
    coordSys = '';
    devLabel = '';
    if isfield(probeInfo, 'Info')
        if isfield(probeInfo.Info, 'CoordinateUnits')
            coordUnits = probeInfo.Info.CoordinateUnits;
        end
        if isfield(probeInfo.Info, 'CoordinateSystem')
            coordSys = probeInfo.Info.CoordinateSystem;
        end
        if isfield(probeInfo.Info, 'CfgName') && ~isempty(probeInfo.Info.CfgName)
            devLabel = probeInfo.Info.CfgName;
        elseif isfield(probeInfo.Info, 'Name')
            devLabel = probeInfo.Info.Name;
        end
    end

    probeCount = 0;
    for j = 1:length(probeInfo.cfg.Sections)
        sectionName = probeInfo.cfg.Sections{j};
        if contains(sectionName, 'Probe')
            probeCount = probeCount + 1;
            p = get(probeInfo.cfg, sectionName);
            p = initializeProbeStructure(p);
            p = processChannelInfo(p);

            % A device may be "layout-only": defined by channels (+ an optional
            % grid) with NO physical optode coordinates. Route those around the
            % position/projection pipeline so they still load as plottable
            % grid devices instead of erroring on missing positions.
            has2D = isfield(p, 'DetPosX') && isfield(p, 'SrcPosX');
            has3D = isfield(p, 'DetPos3DX') && isfield(p, 'SrcPos3DX');
            anyPos = isfield(p, 'DetPosX') || isfield(p, 'SrcPosX') ...
                || isfield(p, 'DetPos3DX') || isfield(p, 'SrcPos3DX');
            if anyPos && ~(has2D || has3D)
                lbl = devLabel; if isempty(lbl), lbl = 'this device'; end
                warning('pf2:loadDeviceCfg:partialPositions', ...
                    ['%s: partial position fields present but a complete ' ...
                     'detector+source set is missing; treating as layout-only ' ...
                     'and ignoring the partial coordinates.'], lbl);
            end
            if has2D || has3D
                p = processPositionInfo(p, coordUnits, devLabel);
                p = calculateSourceDetectorSeparation(p);
                p = generateProbeLayout(p, includeSSchannels);
            else
                p = buildLayoutOnlyProbe(p);
            end

            p = sortOptodes(p); % and drop any in DropOptodes

            % Declared/auto flat "schematic" layout (clean grid for explanatory
            % plotting), independent of the affine 3D->2D projection above.
            p = generateSchematicLayout(p);

            % Sanity-check 3D coordinates against MNI expectations (warn only).
            checkCoordinateBounds(p, coordSys, devLabel);

            fieldsToRemove={'SrcPosX','SrcPosY','SrcPosZ','SrcPos3DX','SrcPos3DY','SrcPos3DZ' ...
                'DetPosX','DetPosY','DetPosZ','DetPos3DX','DetPos3DY','DetPos3DZ'...
                'OptPosX','OptPosY','OptPosZ','OptPos3DX','OptPos3DY','OptPos3DZ'...
                'sI','dI','ChannelList','SD','IsShortSeparation','OptLayout2D','Wavelength','ChannelNumbers','OptPos3D_mean','PlotStructure'};

            % Only remove fields that are actually present (layout-only devices
            % never create the position/projection fields).
            p = rmfield(p, fieldsToRemove(isfield(p, fieldsToRemove)));

            if(includeSSchannels) && isfield(p, 'OptLayout2D_ss')
                p=rmfield(p,'OptLayout2D_ss');
            end

            probeInfo.Probe{probeCount} = p;
        end
    end
end

function p = initializeProbeStructure(p)
    tempChannels = unique(p.ChannelNumbers);
      if(~isfield(p,'ChannelList'))
            p.ChannelList=tempChannels(tempChannels>0);
        elseif(length(tempChannels(tempChannels>0))~=length(p.ChannelList))
            error('pf2_base:loadDeviceCfg:channelCountMismatch', 'Manually defined channel list different number of channels than found in Channel Numbers list');
      end
    p.NumOptodes = length(p.ChannelList);
    p.TableOpt = table('Size', [p.NumOptodes, 1], 'VariableTypes', {'double'}, 'VariableNames', {'OptodeNum'});
    p.TableOpt.OptodeNum = p.ChannelList(:);
    if isfield(p, 'ChannelLabels')
        p.TableOpt.Label = p.ChannelLabels;
    end
    p.TableSD = table();
    p.TableCh = table();
end

function p = processChannelInfo(p)
    p.TableCh.ColNumber = (1:length(p.ChannelNumbers))';
    p.TableCh.OptodeNumber = p.ChannelNumbers(:);
    p.TableCh.isTime = p.TableCh.OptodeNumber == 0;
    if(sum(p.TableCh.isTime)>1)
       warning('More than one time column specified, please set only one channel to be # 0. Using first ch 0 column');
       firstIdx=find(p.TableCh.isTime);
       p.TableCh.isTime(firstIdx+1:end)=false;
    end
    p.TableCh.isMarker = p.TableCh.OptodeNumber < 0 | isnan(p.TableCh.OptodeNumber);
    p.TableCh.OptodeNumber(p.TableCh.OptodeNumber < 1) = nan;
    
    validCols = ~isnan(p.TableCh.OptodeNumber);
    
    channelIdx = p.TableCh.OptodeNumber(validCols);
    
    if(min(channelIdx)>1 || max(channelIdx)>length(p.ChannelList))
        if(~isequal(unique(channelIdx),unique(p.ChannelList)))
             warning('Assuming source and detector indicies are sorted accoring to their ordinal appearance');
             channelMap = containers.Map('KeyType', 'double', 'ValueType', 'double');
                for i = 1:length(p.ChannelList)
                    channelMap(p.ChannelList(i)) = i;
                end
                
                % Map each value in channelIdx to its index in channelList
                mappedIndices = zeros(size(channelIdx));
                for i = 1:length(channelIdx)
                    if isKey(channelMap, channelIdx(i))
                        mappedIndices(i) = channelMap(channelIdx(i));
                    else
                        error('pf2_base:loadDeviceCfg:channelNotFound', 'Channel %d not found in channelList', channelIdx(i));
                    end
                end

                channelIdx=mappedIndices;
        end
    end
    
    p.TableCh.Wavelength = p.Wavelength(:);
    p.TableCh.SourceIndex = nan(size(p.TableCh.OptodeNumber));
    p.TableCh.DetectorIndex = nan(size(p.TableCh.OptodeNumber));
    % Source/detector wiring is optional: layout-only devices (grid montage,
    % no physical optode positions) may omit sI/dI. Leave indices NaN then.
    if isfield(p, 'sI') && isfield(p, 'dI')
        p.TableCh.SourceIndex(validCols) = p.sI(channelIdx);
        p.TableCh.DetectorIndex(validCols) = p.dI(channelIdx);
    end
    
    p.TableCh.isDark = (isnan(p.TableCh.Wavelength) | p.TableCh.Wavelength == 0) & validCols;
    p.TableCh.isCh = validCols(:);
    
    p.TableCh.Label = repmat("", size(p.TableCh.OptodeNumber));
    
    p = assignChannelLabels(p);
end

function p = assignChannelLabels(p)
    for ch = 1:length(p.ChannelNumbers)
        if p.TableCh.isTime(ch)
            p.TableCh.Label(ch) = "Time";
        elseif p.TableCh.isMarker(ch)
            p.TableCh.Label(ch) = "Mrk";
        elseif p.TableCh.isDark(ch)
            opt = p.TableCh.OptodeNumber(ch);
            p.TableCh.Label(ch) = sprintf('Opt%i_dark', opt);
        else
            wv = p.TableCh.Wavelength(ch);
            opt = p.TableCh.OptodeNumber(ch);
            p.TableCh.Label(ch) = sprintf('Opt%i_wv%.1f', opt, wv);
        end
    end
end

function p = processPositionInfo(p, coordUnits, devLabel)
    if nargin < 2, coordUnits = ''; end
    if nargin < 3, devLabel = ''; end

    % If no 2D info but 3D is present, derive a 2D layout from the 3D
    % coordinates, converting the DECLARED 3D units to the centimetre scale the
    % 2D layout engine expects (legacy behaviour assumed mm, i.e. /10).
    if ~isfield(p, 'DetPosX') && ~isfield(p, 'SrcPosX') && isfield(p, 'DetPos3DX') && isfield(p, 'SrcPos3DX')
        [scale, unitStr] = unitsToCmScale(coordUnits);
        if isempty(devLabel), devLabel = 'this device'; end
        warning('pf2:loadDeviceCfg:no2DPositions', ...
            ['No 2D position info for %s; deriving a 2D layout from 3D ' ...
             '(%s) coordinates scaled by %.4g to cm.'], devLabel, unitStr, scale);
        p.SrcPosX = p.SrcPos3DX * scale;
        p.SrcPosY = p.SrcPos3DY * scale;
        p.SrcPosZ = p.SrcPos3DZ * scale;
        p.DetPosX = p.DetPos3DX * scale;
        p.DetPosY = p.DetPos3DY * scale;
        p.DetPosZ = p.DetPos3DZ * scale;
    end

    hasX= isfield(p, 'DetPosX') && isfield(p, 'SrcPosX');
    hasY = isfield(p, 'DetPosY') && isfield(p, 'SrcPosY');
    hasZ = isfield(p, 'DetPosZ') && isfield(p, 'SrcPosZ');
    xyz=(hasX+hasY+hasZ);

    if(xyz<1)
       error('pf2_base:loadDeviceCfg:noPositionInfo', 'No position information provided for device');
    end

    if(xyz==1)
        warning('Only one dimension provided, other dimensons will be zeromapped');
    end
    
    if(hasX)
        nDet= length(p.DetPosX);
        nSrc = length(p.SrcPosX);
    elseif(hasY)
        nDet= length(p.DetPosY);
        nSrc = length(p.SrcPosY);
    else
        nDet= length(p.DetPosZ);
        nSrc = length(p.SrcPosZ);
    end

    if(~hasX)
        p.DetPosX=zeros([1,nDet]);
        p.SrcPosX=zeros([1,nSrc]);
    end

    if(~hasY)
        p.DetPosY=zeros([1,nDet]);
        p.SrcPosY=zeros([1,nSrc]);
    end

    if(~hasZ)
        p.DetPosZ=zeros([1,nDet]);
        p.SrcPosZ=zeros([1,nSrc]);
    end


    if isfield(p, 'DetPosX') && isfield(p, 'SrcPosX')
        return;
    else
        error('pf2_base:loadDeviceCfg:noPositionInfo', 'No position info is available');
    end
end

function p=calculateSourceDetectorSeparation(p)

    useIdx = isfield(p,'dI')&&isfield(p,'sI');    
    has3D = isfield(p,'DetPos3DX')&&isfield(p,'SrcPos3DX') ...
        &&isfield(p,'DetPos3DY')&&isfield(p,'SrcPos3DY')...
        &&isfield(p,'DetPos3DZ')&&isfield(p,'SrcPos3DZ');
        
    if(isfield(p,'SDLabels'))
        p.TableSD.Label=p.SDLabels(:);
    end
    
        
    if(useIdx)
        % Assign src/det types
        Type_temp=[ones(size(p.SrcPosX(:)));ones(size(p.DetPosX(:)))*2];
                
        typeStr_temp={'Src','Det'};
        
        catType_temp=categorical(typeStr_temp(Type_temp(:)),typeStr_temp);
        p.TableSD.Type=catType_temp(:);
        
        
        
        p.TableSD.Index=[(1:length(p.SrcPosX(:)))';(1:length(p.DetPosX(:)))'];
        
        %Assign labels
        if(~ismember('Label',p.TableSD.Properties.VariableNames))
            sdLabels=cell(length(p.TableSD.Index),1);
            for sd=1:length(p.TableSD.Index)
                typeLabel=char(p.TableSD.Type(sd));
                sdLabels{sd}=sprintf('%s%i',typeLabel(1),p.TableSD.Index(sd));
            end
            p.TableSD.Label=sdLabels;
        end

        %Assign source/detector idx
        p.TableOpt.SrcIdx=p.sI(:);
        p.TableOpt.DetIdx=p.dI(:);

        % Fill in 2D X positions
        p.TableSD.Pos2D_x=[p.SrcPosX(:);p.DetPosX(:)];
        
        p.SrcPosX=p.SrcPosX(p.sI);
        p.DetPosX=p.DetPosX(p.dI);
        
        % Fill in 2D Y positions
        p.TableSD.Pos2D_y=[p.SrcPosY(:);p.DetPosY(:)];
                
        p.SrcPosY=p.SrcPosY(p.sI);
        p.DetPosY=p.DetPosY(p.dI);

        % Fill in 2D Z positions
        p.TableSD.Pos2D_z=[p.SrcPosZ(:);p.DetPosZ(:)];
        p.SrcPosZ=p.SrcPosZ(p.sI);
        p.DetPosZ=p.DetPosZ(p.dI);

        if(has3D)
            p.TableSD.Pos3D_x=[p.SrcPos3DX(:);p.DetPos3DX(:)];
            p.SrcPos3DX=p.SrcPos3DX(p.sI);
            p.DetPos3DX=p.DetPos3DX(p.dI);
            
            p.TableSD.Pos3D_y=[p.SrcPos3DY(:);p.DetPos3DY(:)];
            p.SrcPos3DY=p.SrcPos3DY(p.sI);
            p.DetPos3DY=p.DetPos3DY(p.dI);
            
            p.TableSD.Pos3D_z=[p.SrcPos3DZ(:);p.DetPos3DZ(:)];
            p.SrcPos3DZ=p.SrcPos3DZ(p.sI);
            p.DetPos3DZ=p.DetPos3DZ(p.dI);
        end

    end

    % Should have 2d position info
    p.OptPosX=nanmean([p.DetPosX(:)';p.SrcPosX(:)'],1)';
    p.TableOpt.Pos2D_x=p.OptPosX;

    p.OptPosY=nanmean([p.DetPosY(:)';p.SrcPosY(:)'],1)';
    p.TableOpt.Pos2D_y=p.OptPosY;

    p.OptPosZ=nanmean([p.DetPosZ(:)';p.SrcPosZ(:)'],1)';
    p.TableOpt.Pos2D_z=p.OptPosZ;

    if(has3D) % prefer over 2D for position + SD calculation
        % Allow these to be manually defined if they already exist
        if(~(isfield(p,'OptPos3DX')&&isfield(p,'OptPos3DY')&&isfield(p,'OptPos3DZ')))
            p.OptPos3DX=nanmean([p.DetPos3DX(:)';p.SrcPos3DX(:)'],1)';
            p.OptPos3DY=nanmean([p.DetPos3DY(:)';p.SrcPos3DY(:)'],1)';
            p.OptPos3DZ=nanmean([p.DetPos3DZ(:)';p.SrcPos3DZ(:)'],1)';
        end
        p.TableOpt.Pos3D_x=p.OptPos3DX(:);
        p.TableOpt.Pos3D_y=p.OptPos3DY(:);
        p.TableOpt.Pos3D_z=p.OptPos3DZ(:);
    end
        
    % Use 2D values here for simplicity and consistency (may want to update
    % if using 3D digitized values per participant)
   p.SD=sqrt((p.DetPosX-p.SrcPosX).^2+(p.DetPosY-p.SrcPosY).^2+(p.DetPosZ-p.SrcPosZ).^2);
   p.TableOpt.SD=p.SD(:);
          
           
   p.IsShortSeparation=p.SD<2;
   p.TableOpt.IsShortSeparation=p.IsShortSeparation(:);
   p.NumShortSeparation=sum(p.IsShortSeparation);
end

function  p=generateProbeLayout(p,includeSSchannels)
    if(isfield(p,'OptPosX')&&isfield(p,'OptPosY')&&~isfield(p,'OptPosZ'))
        if(includeSSchannels)
            p.OptLayout2D_ss=pf2_base.fitProbe2D(p.OptPosX,p.OptPosY);
        end
        p.OptLayout2D=pf2_base.fitProbe2D(p.OptPosX(~p.IsShortSeparation),p.OptPosY(~p.IsShortSeparation));
    end
    if(isfield(p,'OptPosX')&&isfield(p,'OptPosY')&&isfield(p,'OptPosZ'))
        if(includeSSchannels)
            p.OptLayout2D_ss=pf2_base.fitProbe2D(p.OptPosX,p.OptPosY,p.OptPosZ);
        end
        p.OptLayout2D=pf2_base.fitProbe2D(p.OptPosX(~p.IsShortSeparation),p.OptPosY(~p.IsShortSeparation),p.OptPosZ(~p.IsShortSeparation));
            
        
    else
        warning('buildProbeLayout option selected, but not enough information to generate Optode locations');
        p.OptLayout2D=setUpFalse2D(p.NumOptodes);  % generate false channels if not requested
    end
        
    hasLabel=ismember('Label',p.TableOpt.Properties.VariableNames);
    
    xyzPresent=ismember({'Pos3D_x','Pos3D_y','Pos3D_z'},p.TableOpt.Properties.VariableNames);
    xyzPresentSD=ismember({'Pos3D_x','Pos3D_y','Pos3D_z'},p.TableSD.Properties.VariableNames);
    xyzSD=[];
    
    if(all(xyzPresent))
        xyz=[p.TableOpt.Pos3D_x,p.TableOpt.Pos3D_y,p.TableOpt.Pos3D_z];
        
        if(all(xyzPresentSD))
            xyzSD=[p.TableSD.Pos3D_x,p.TableSD.Pos3D_y,p.TableSD.Pos3D_z];
        end
    elseif(sum(xyzPresent)==2)
        xyzStrs={'Pos3D_x','Pos3D_y','Pos3D_z'};
        xyzPresent=find(xyzPresent);
        xyz=[p.TableOpt.(xyzStrs{xyzPresent(1)}),p.TableOpt.(xyzStrs{xyzPresent(2)}),zeros(length(p.ChannelList),1)];
        xyzSD=[p.TableSD.(xyzStrs{xyzPresent(1)}),p.TableSD.(xyzStrs{xyzPresent(2)}),zeros(length(p.ChannelList),1)];
        if(any(xyzPresentSD))
            xyzSD=[p.TableSD.Pos3D_x,p.TableSD.Pos3D_y,p.TableSD.Pos3D_z];
        end
    elseif(sum(xyzPresent)==1)
        xyzStrs={'Pos3D_x','Pos3D_y','Pos3D_z'};
        xyzPresent=find(xyzPresent);
        xyz=[p.TableOpt.(xyzStrs{xyzPresent(1)}),zeros(length(p.ChannelList),2)];
        xyzSD=[p.TableSD.(xyzStrs{xyzPresent(1)}),zeros(length(p.ChannelList),2)];
        if(any(xyzPresentSD))
            xyzSD=[p.TableSD.Pos3D_x,p.TableSD.Pos3D_y,p.TableSD.Pos3D_z];
        end
    else
        xyz=[(1:length(p.ChannelList))',zeros(length(p.ChannelList),2)];
        xyz=xyz*30; %Default spacing 30mm
        xyzSD=[]; %Don't know what to do for this
    end
        
    l1=size(xyz,1);
    l2=size(xyzSD,1);
    plane2D=affine_fit([xyz;xyzSD]);
    
    plane2D_opt=plane2D(1:l1,:);
    plane2D_sd=plane2D(end-l2+1:1:end,:);
    
    zeroCoordIndex=sum(round(abs(plane2D)),1)==0;
    
     p.TableOpt.proj2D=plane2D_opt(:,zeroCoordIndex);
     
     if(~isempty(plane2D_sd))
        p.TableSD.proj2D=plane2D_sd(:,zeroCoordIndex);
     end
     
    % Build the per-optode columns whole, then assign; growing a table
    % variable by indexed assignment is MATLAB-only behavior.
    [chMap, wvMap, optLabels] = optodeColumnMaps(p);
    p.TableOpt.Ch = chMap;
    p.TableOpt.wv = wvMap;
    if(~hasLabel)
        p.TableOpt.Label=optLabels;
    end
    
    p.OptPos3D_mean=nanmean(xyz,1);
        
    p.SrcPos=table();
    p.SrcPos.x_2d=p.SrcPosX(:);
    p.SrcPos.y_2d=p.SrcPosY(:);
    p.SrcPos.z_2d=p.SrcPosZ(:);
    p.SrcPos.x=p.SrcPos3DX(:);
    p.SrcPos.y=p.SrcPos3DY(:);
    p.SrcPos.z=p.SrcPos3DZ(:);
    
    
    p.DetPos=table();
    p.DetPos.x_2d=p.DetPosX(:);
    p.DetPos.y_2d=p.DetPosY(:);
    p.DetPos.z_2d=p.DetPosZ(:);
    p.DetPos.x=p.DetPos3DX(:);
    p.DetPos.y=p.DetPos3DY(:);
    p.DetPos.z=p.DetPos3DZ(:);
    
    % OptPos coordinate columns (x/y/z, x_2d/y_2d/z_2d) are a derived view of
    % the canonical TableOpt.Pos3D_*/Pos2D_* -- written through one helper so
    % the two stores cannot diverge.
    p.OptPos=table();
    p = pf2_base.syncOptodeCoords(p);

    % Size the layout off the channel count, not a coordinate column, so a
    % 2D-only device (no Pos3D -> no OptPos.z) still builds a layout.
    p.OptPos.subplot_layout=cell(p.NumOptodes,1);
    p.OptPos.subplot_layout(~p.IsShortSeparation)=p.OptLayout2D(:);
    if(includeSSchannels)
        p.OptPos.subplot_layout_ss=p.OptLayout2D_ss(:);
    else
       p.OptPos.subplot_layout_ss= p.OptPos.subplot_layout;
    end
    
   
end

function checkCoordinateBounds(p, coordSys, devLabel)
% CHECKCOORDINATEBOUNDS Two-tier sanity check on declared-MNI 3D coordinates.
%
% Warns (never errors) when optode coordinates look inconsistent with MNI-space
% millimetres: too large (likely cm read as mm, a voxel index, or a swapped
% axis) or too small in extent (likely cm mislabelled as mm). Only runs when
% the device declares CoordinateSystem = 'MNI'.
    if isempty(coordSys) || ~strcmpi(strtrim(char(coordSys)), 'MNI')
        return;
    end
    if ~isfield(p, 'TableOpt') || ~istable(p.TableOpt)
        return;
    end
    vn = p.TableOpt.Properties.VariableNames;
    if ~all(ismember({'Pos3D_x','Pos3D_y','Pos3D_z'}, vn))
        return;
    end
    XYZ = [p.TableOpt.Pos3D_x(:), p.TableOpt.Pos3D_y(:), p.TableOpt.Pos3D_z(:)];
    XYZ = XYZ(all(~isnan(XYZ), 2), :);
    if isempty(XYZ)
        return;
    end
    if isempty(devLabel), devLabel = 'this device'; end

    % Tier 1 - implausibly large for a scalp-mounted MNI montage (mm).
    maxAbs = max(abs(XYZ(:)));
    if maxAbs > 150
        warning('pf2:loadDeviceCfg:coordsTooLarge', ...
            ['%s: MNI optode coordinate magnitude %.1f mm exceeds ~150 mm. ' ...
             'Check units (cm/voxel index?) or axis assignment.'], devLabel, maxAbs);
    end

    % Tier 2 - implausibly tight optode spacing: likely cm mislabelled as mm.
    % Uses median nearest-neighbour spacing (robust to montage size) rather
    % than total span, so a small but legitimate patch is not flagged while a
    % cm-as-mm error (~3 mm spacing instead of ~30 mm) still is.
    n = size(XYZ, 1);
    if n > 1
        nn = inf(n, 1);
        for a = 1:n
            for b = 1:n
                if a == b, continue; end
                d = norm(XYZ(a, :) - XYZ(b, :));
                if d < nn(a), nn(a) = d; end
            end
        end
        medNN = median(nn(isfinite(nn)));
        if isfinite(medNN) && medNN < 8
            warning('pf2:loadDeviceCfg:coordsTooSmall', ...
                ['%s: median optode spacing is only %.1f mm; coordinates may be ' ...
                 'in cm mislabelled as mm (CoordinateUnits).'], devLabel, medNN);
        end
    end
end

function [scale, unitStr] = unitsToCmScale(coordUnits)
% UNITSTOCMSCALE Factor converting declared 3D coordinate units to centimetres.
%
% Returns the multiplicative scale and a human-readable unit string for the
% warning. When units are undeclared the legacy mm assumption is preserved but
% flagged as a guess.
    u = lower(strtrim(char(coordUnits)));
    switch u
        case {'mm','millimeter','millimetre','millimeters','millimetres'}
            scale = 0.1;  unitStr = 'mm';
        case {'cm','centimeter','centimetre','centimeters','centimetres'}
            scale = 1;    unitStr = 'cm';
        case {'m','meter','metre','meters','metres'}
            scale = 100;  unitStr = 'm';
        case ''
            scale = 0.1;  unitStr = 'mm (assumed; CoordinateUnits not declared)';
        otherwise
            scale = 0.1;  unitStr = sprintf('%s (unrecognized; assuming mm)', u);
    end
end

function p = buildLayoutOnlyProbe(p)
% BUILDLAYOUTONLYPROBE Assemble a device defined by channels + grid only.
%
% For devices with no physical optode coordinates (e.g. a montage described
% solely by a PlotStructure grid). Produces the minimum TableOpt/OptPos needed
% for grid plotting and the Device accessors, using the provided SD field for
% short-separation classification. No Pos2D/Pos3D are created, so hasMNI()
% stays false and the schematic grid becomes the device's only layout.

    n = p.NumOptodes;

    % Per-channel source-detector distance from the provided SD field, if it
    % matches the channel count; otherwise unknown.
    sd = nan(n, 1);
    if isfield(p, 'SD') && numel(p.SD) == n
        sd = p.SD(:);
    end
    isSS = sd < 2;          % NaN < 2 is false
    isSS(isnan(sd)) = false;
    p.SD = sd;
    p.IsShortSeparation = isSS;
    p.NumShortSeparation = sum(isSS);

    p.TableOpt.SD = sd;
    p.TableOpt.IsShortSeparation = isSS(:);

    % Carry optional source/detector wiring through if the cfg declares it.
    if isfield(p, 'sI') && isfield(p, 'dI') ...
            && numel(p.sI) == n && numel(p.dI) == n
        p.TableOpt.SrcIdx = p.sI(:);
        p.TableOpt.DetIdx = p.dI(:);
    end

    % OptPos host table, sized to the channel count so sortOptodes can reorder
    % it in step with TableOpt. No physical coordinates exist (layout-only), so
    % the single NaN column is a row-count seed, not a real position.
    p.OptPos = table();
    p.OptPos.z = nan(n, 1);

    % Per-channel raw-column map + labels (mirrors generateProbeLayout's tail).
    hasLabel = ismember('Label', p.TableOpt.Properties.VariableNames);
    [chMap, wvMap, optLabels] = optodeColumnMaps(p);
    p.TableOpt.Ch = chMap;
    p.TableOpt.wv = wvMap;
    if ~hasLabel
        p.TableOpt.Label = optLabels;
    end

    % A PlotStructure grid ([row col channel] rows) becomes a declared layout.
    if isfield(p, 'PlotStructure') && ~isempty(p.PlotStructure) && size(p.PlotStructure, 2) >= 3
        ps = p.PlotStructure;
        rows = max(ps(:, 1)); cols = max(ps(:, 2));
        order = zeros(1, n);
        for r = 1:size(ps, 1)
            ci = find(p.ChannelList == ps(r, 3), 1);
            if ~isempty(ci)
                order(ci) = (ps(r, 1) - 1) * cols + ps(r, 2);
            end
        end
        if all(order > 0)
            p.LayoutRows = rows;
            p.LayoutCols = cols;
            p.LayoutOrder = order;
        end
    end
end

function p = generateSchematicLayout(p)
% GENERATESCHEMATICLAYOUT Build a clean flat "schematic" montage layout.
%
% Produces subplot_layout_schematic (standard channels, aligned 1:1 with
% subplot_layout) and subplot_layout_schematic_ss (all channels) on p.OptPos,
% plus a p.LayoutDeclared flag. Unlike the affine 3D->2D projection, this is a
% tidy grid intended for explanatory plotting (e.g. a 2x8 montage).
%
% Layout source, in priority order:
%   1. Explicit per-channel Layout2D_x / Layout2D_y (normalized, any shape)
%   2. Declared grid LayoutRows / LayoutCols (+ optional LayoutOrder)
%   3. Auto near-square grid fallback (best-effort; NOT a declared montage)

    nAll = p.NumOptodes;
    if isfield(p, 'IsShortSeparation')
        isSS = logical(p.IsShortSeparation(:));
    else
        isSS = false(nAll, 1);
    end
    if numel(isSS) ~= nAll
        isSS = false(nAll, 1);
    end
    nNonSS = sum(~isSS);

    hasXY   = isfield(p, 'Layout2D_x') && isfield(p, 'Layout2D_y');
    hasGrid = isfield(p, 'LayoutRows') && isfield(p, 'LayoutCols');
    p.LayoutDeclared = hasXY || hasGrid;

    order = [];
    if isfield(p, 'LayoutOrder')
        order = p.LayoutOrder(:)';
    end
    pad = 0.15;  % fractional gap between grid cells

    if hasXY
        xv = p.Layout2D_x(:); yv = p.Layout2D_y(:);
        if numel(xv) == nAll
            cellsAll = buildXYCells(xv, yv);
            cellsNon = cellsAll(~isSS);
        elseif numel(xv) == nNonSS
            cellsNon = buildXYCells(xv, yv);
            cellsAll = buildAutoGridCells(nAll, order, pad);
            cellsAll(~isSS) = cellsNon;
        else
            warning('pf2:loadDeviceCfg:layoutSize', ...
                ['Layout2D_x/y length (%d) matches neither channel count ' ...
                 '(%d all / %d standard); using auto grid.'], numel(xv), nAll, nNonSS);
            p.LayoutDeclared = false;
            cellsNon = buildAutoGridCells(nNonSS, [], pad);
            cellsAll = buildAutoGridCells(nAll, [], pad);
        end
    elseif hasGrid
        cellsNon = buildGridCells(nNonSS, p.LayoutRows, p.LayoutCols, order, pad);
        cellsAll = buildGridCells(nAll, p.LayoutRows, p.LayoutCols, order, pad);
    else
        cellsNon = buildAutoGridCells(nNonSS, [], pad);
        cellsAll = buildAutoGridCells(nAll, [], pad);
    end

    % Place into full-size cell columns indexed by optode row (matches the
    % subplot_layout convention: standard channels filled, SS left empty).
    schemNon = cell(nAll, 1);
    schemNon(~isSS) = cellsNon(:);
    p.OptPos.subplot_layout_schematic = schemNon;
    p.OptPos.subplot_layout_schematic_ss = cellsAll(:);

    % Layout-only devices have no affine projection: make the schematic grid the
    % device's default layout too, so 'anatomical'/'auto' plots still work.
    if ~ismember('subplot_layout', p.OptPos.Properties.VariableNames)
        p.OptPos.subplot_layout = schemNon;
    end
    if ~ismember('subplot_layout_ss', p.OptPos.Properties.VariableNames)
        p.OptPos.subplot_layout_ss = cellsAll(:);
    end

    % Drop the raw layout specs now that they are baked into the layout cells.
    for fn = {'LayoutRows','LayoutCols','LayoutOrder','Layout2D_x','Layout2D_y'}
        if isfield(p, fn{1})
            p = rmfield(p, fn{1});
        end
    end
end

function cells = buildGridCells(n, rows, cols, order, pad)
% Row-major rectangles in normalized [0,1] coords, row 1 at the top.
    rows = double(rows); cols = double(cols);
    if isempty(order) || numel(order) ~= n
        order = 1:n;
    end
    if rows * cols < n   % declared grid too small: fall back to near-square
        cols = ceil(sqrt(n));
        rows = ceil(n / cols);
        order = 1:n;
    end
    w = 1 / cols; h = 1 / rows;
    cells = cell(n, 1);
    for i = 1:n
        slot = order(i);
        rr = ceil(slot / cols);
        cc = slot - (rr - 1) * cols;
        x = (cc - 1) * w + pad * w / 2;
        y = (rr - 1) * h + pad * h / 2;   % row 1 renders at the top (imageValues flips y)
        cells{i} = [x, y, w * (1 - pad), h * (1 - pad)];
    end
end

function cells = buildAutoGridCells(n, order, pad)
% Near-square grid; a best-effort fallback, not a declared montage.
    cols = ceil(sqrt(n));
    rows = ceil(n / cols);
    cells = buildGridCells(n, rows, cols, order, pad);
end

function cells = buildXYCells(xv, yv)
% Normalize arbitrary 2D positions into [0,1] and build uniform rectangles.
    xv = xv(:); yv = yv(:);
    n = numel(xv);
    rngx = max(xv) - min(xv); if rngx == 0, rngx = 1; end
    rngy = max(yv) - min(yv); if rngy == 0, rngy = 1; end
    m = 0.10;  % outer margin
    nx = m + (1 - 2 * m) * (xv - min(xv)) / rngx;
    ny = m + (1 - 2 * m) * (yv - min(yv)) / rngy;
    % Cell size from nearest-neighbour spacing (keeps tiles from overlapping).
    if n > 1
        minD = inf;
        for a = 1:n
            for b = a+1:n
                d = hypot(nx(a) - nx(b), ny(a) - ny(b));
                if d < minD, minD = d; end
            end
        end
        if ~isfinite(minD) || minD == 0, minD = 0.2; end
        wch = max(0.04, min(0.18, 0.6 * minD));
    else
        wch = 0.18;
    end
    cells = cell(n, 1);
    for i = 1:n
        cells{i} = [nx(i) - wch / 2, ny(i) - wch / 2, wch, wch];
    end
end

function p = sortOptodes(p)

    [uOpt,b,c]= unique(p.ChannelList);

    numCh=length(uOpt);

    if(isfield(p,'DropOptodes'))
        opt2Drop=ismember(uOpt,p.DropOptodes);
        uOpt=uOpt(~opt2Drop);
        b=b(~opt2Drop);

        p.TableCh.Dropped = p.TableCh.OptodeNumber>0.&ismember(p.TableCh.OptodeNumber,p.DropOptodes);
        p.TableCh.isCh = p.TableCh.isCh & ~p.TableCh.Dropped;
    end

    if(isequal(uOpt,p.ChannelList))
        return
    end

    

    fieldsToSort = {'DetPosX','DetPosY','DetPosZ','SrcPosX','SrcPosY','SrcPosZ'...
            'DetPos3DX','DetPos3DY','DetPos3DZ','SrcPos3DX','SrcPos3DY','SrcPos3DZ', 'sI','dI'...
            'ChannelList','OptPosX','OptPosY','OptPosZ','OptPos3DX','OptPos3DY','OptPos3DZ','SD','IsShortSeparation'...
            'OptLayout2D_ss','OptLayout2D','SrcPos','DetPos','OptPos','TableOpt'};

    for f=1:length(fieldsToSort)
        if(isfield(p,fieldsToSort{f}))
            if(istable(p.(fieldsToSort{f})))
                p.(fieldsToSort{f})=p.(fieldsToSort{f})(b,:);
            else
    
                nD=find(size(p.(fieldsToSort{f}))==numCh);
                if(nD==1)
                    p.(fieldsToSort{f})=p.(fieldsToSort{f})(b);
                elseif(nD==2)
                    p.(fieldsToSort{f})=p.(fieldsToSort{f})(:,b);
                end
            end
        end
    end

    p.TableOpt = sortrows(p.TableOpt,'OptodeNum');

   

    p.NumOptodes = height(p.TableOpt);

end

function [chMap, wvMap, labels] = optodeColumnMaps(p)
% OPTODECOLUMNMAPS Per-optode raw-column indices, wavelengths, and labels
%
% Inputs:
%   p - Probe info struct with ChannelList, ChannelNumbers, Wavelength
%
% Outputs:
%   chMap  - [nOpt x maxWv] raw column index per optode (zero-padded)
%   wvMap  - [nOpt x maxWv] wavelength per column (zero-padded)
%   labels - {nOpt x 1} default labels 'Opt<N>'

    nOpt   = length(p.ChannelList);
    chMap  = zeros(nOpt, 0);
    wvMap  = zeros(nOpt, 0);
    labels = cell(nOpt, 1);
    for c = 1:nOpt
        chIdxMatch = find(p.ChannelNumbers == p.ChannelList(c));
        chMap(c, 1:length(chIdxMatch)) = chIdxMatch;
        wvMap(c, 1:length(chIdxMatch)) = p.Wavelength(chIdxMatch);
        labels{c} = sprintf('Opt%i', p.ChannelList(c));
    end
end
