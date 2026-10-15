function varargout = exploreFNIRS(varargin) % exploreFNIRS(data,timeShiftTo0,blStart,blEnd,blockStart,blockEnd,plotStart,plotEnd,barSegmentLength)
% exploreFNIRS is a program which organizes experimental FNIRS data into an exportable table, or for plotting
%		Accepts a cell array of FNIRS structs (ideally with populated FNIRS.info fields and timeshifted so that the task/segment of interest starts at t=0 or the same time)
%		Use the Groupby buttons to specify important grouping levels such as Session X Condition or Group X Trial depending on your variables of interest
%		Behavioral and FNIRS data is averaged by default according to the within subject heirarchy options
%			ie: a subjects average score is the average of their sessions each of which is the average of all trials (this hierarchy can be changed in the GUI)
%			Alternatively averaging can be set to Flat to change it so that subject data is averaged without respect to experimental hierarchy (necessary for LME models)
% %			ie: a subjects average score is the average of all their scores regardless of how many trials are in each session
%		Plots are generated based on your groupby selection and the number of optodes/biomarkers you have selected to plot simultaneously
%			There is an additional plotby button which allows one of the groupby factors to be used to split plots based on that factor
%			(Otherwise all groups show up as different colors on the same plot)
%		A variable from the info field may be assigned as a groupby factor (best used for non-numeric data)
%		A second variable from the info field may be plotted and optionally used as a covariate in the LME outputs
%		Plot colors may be selected automatically using defined color maps (or a mycolorfunc you define)
%			Additionally manual colors may be saved/loaded in a 3x10color csv file (rows are r,g,b (from 0 to 1) and each column is a color)
%		Exported data will come out as a CSV file with all barchart timepoints and All biomarkers for the currently selected groups (in wide format)
%			Exporting as a MAT file will also contain grand average structs and other data

% Todo
%	Implement units in plots (currently just assumes uM)
%	Implement efficiency plots
%	Implement post-hoc for LME
%	Implement GLM approach for temporal data
%	Implement region of interest grouping for channels
%	Implement more flexible LME model options
%	Better/3D parametric plots
%	Parametric plots for correlation
%	Ability to plot/analyze aux data

% See CHANGELOG.md for version history

% EXPLOREFNIRS MATLAB code for exploreFNIRS.fig
%      EXPLOREFNIRS, by itself, creates a new EXPLOREFNIRS or raises the existing
%      singleton*.
%
%      H = EXPLOREFNIRS returns the handle to a new EXPLOREFNIRS or the handle to
%      the existing singleton*.
%
%      EXPLOREFNIRS('CALLBACK',hObject,eventData,handles,...) calls the local
%      function named CALLBACK in EXPLOREFNIRS.M with the given input arguments.
%
%      EXPLOREFNIRS('Property','Value',...) creates a new EXPLOREFNIRS or raises
%      the existing singleton*.  Starting from the left, property value pairs are
%      applied to the GUI before exploreFNIRS_OpeningFcn gets called.  An
%      unrecognized property name or invalid value makes property application
%      stop.  All inputs are passed to exploreFNIRS_OpeningFcn via varargin.
%
%      *See GUI Options on GUIDE's Tools menu.  Choose "GUI allows only one
%      instance to run (singleton)".
%
% See also: GUIDE, GUIDATA, GUIHANDLES

% Edit the above text to modify the response to help exploreFNIRS

% Last Modified by GUIDE v2.5 26-Aug-2019 17:40:22

if pf2_base.env.isOctave()
    error('pf2:gui:octaveUnsupported', ...
        ['exploreFNIRS requires MATLAB. Under Octave, use the programmatic ' ...
         'group-analysis API instead of the GUI.']);
end

% Begin initialization code - DO NOT EDIT
gui_Singleton = 1;
gui_State = struct('gui_Name',       mfilename, ...
                   'gui_Singleton',  gui_Singleton, ...
                   'gui_OpeningFcn', @exploreFNIRS_OpeningFcn, ...
                   'gui_OutputFcn',  @exploreFNIRS_OutputFcn, ...
                   'gui_LayoutFcn',  [] , ...
                   'gui_Callback',   []);
if nargin && ischar(varargin{1})
    gui_State.gui_Callback = str2func(varargin{1});
end

if nargout
    [varargout{1:nargout}] = gui_mainfcn(gui_State, varargin{:});
else
    gui_mainfcn(gui_State, varargin{:});
end
% End initialization code - DO NOT EDIT

% --- Executes just before exploreFNIRS is made visible.
function exploreFNIRS_OpeningFcn(hObject, eventdata, handles, varargin)
% This function has no output args, see OutputFcn.
% hObject    handle to figure
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)
% varargin   command line arguments to exploreFNIRS (see VARARGIN)

% Choose default command line output for exploreFNIRS
handles.output = hObject;

% Update handles structure
guidata(hObject, handles);

pf2_base.applyLightTheme(hObject);

% Add File menu with Import options
mFile = uimenu(hObject, 'Label', 'File');
uimenu(mFile, 'Label', 'Import File...', 'Callback', @(s,e) menu_import_file_Callback(handles));
uimenu(mFile, 'Label', 'Import Directory...', 'Callback', @(s,e) menu_import_dir_Callback(handles));

initialize_gui(hObject, handles, false);

global ExFNIRS

if(~isfield(ExFNIRS,'defaultRootPath'))
    [ExFNIRS_folder,~,~] = fileparts(mfilename('fullpath'));
    ExFNIRS.defaultRootPath=ExFNIRS_folder;
    curdir=cd;
    cd(ExFNIRS.defaultRootPath);
    addpath('base_functions','GUI','functions');
    cd(curdir);
end

% Self-healing: ensure stats-toolbox fallbacks (nan*) are on the path when
% the toolbox is absent (END of path, so the toolbox wins when present).
pf2_base.ensureStatsFallbacks();

set(handles.text_versInfo,'String',exploreFNIRS.versInfo());

warning('OFF','MATLAB:table:RowsAddedExistingVars')
p=inputParser;

validScalarNum = @(x) isnumeric(x) && isscalar(x);
validScalarPosNum = @(x) isnumeric(x) && isscalar(x) && (x > 0);

if(~isfield(ExFNIRS,'settings')||~isfield(ExFNIRS.settings,'baseline_start'))
    ExFNIRS.settings.baseline_start=0;
    ExFNIRS.settings.baseline_end=5;
    ExFNIRS.settings.block_start=5;
    ExFNIRS.settings.block_end=65;
    ExFNIRS.settings.plot_start=[];
    ExFNIRS.settings.plot_end=[];
    ExFNIRS.settings.barchart_resample_size=60;
    ExFNIRS.settings.timeShiftTo0=true;
    ExFNIRS.settings.ChannelMode='fNIR';  % valid is fNIR, ROI, and Aux
    ExFNIRS.settings.ChannelModes={1,'fNIR';2,'ROI';3,'Aux'};
    ExFNIRS.settings.processRaw=get(handles.checkbox_process_raw,'Value');
    ExFNIRS.settings.LME_use_intercept=get(handles.checkbox_LME_use_intercept,'Value');
    ExFNIRS.settings.LME_use_discreteTime=get(handles.checkbox_discreteTime,'Value');
    % Map legacy checkbox to new TimeModel setting
    if ExFNIRS.settings.LME_use_discreteTime
        ExFNIRS.settings.LME_timeModel = 'discrete';
    else
        ExFNIRS.settings.LME_timeModel = 'polynomial';
    end
    ExFNIRS.settings.LME_polyOrder = 2;
    ExFNIRS.settings.LME_randomFxStr='1|SubjectID';
    ExFNIRS.settings.LME_use_customStr=get(handles.checkbox_lme_usecustom,'Value');
    ExFNIRS.settings.topoSigThrehold={'p',0.05};
    ExFNIRS.settings.LME_customStr='';
    ExFNIRS.settings.use_info=true;
    ExFNIRS.settings.use_group=get(handles.checkbox_use_group,'Value');
    ExFNIRS.settings.plot_temporal_y0=get(handles.checkbox_yaxis,'Value');
    ExFNIRS.settings.use_baseline=get(handles.checkbox_usebaseline,'Value');
    ExFNIRS.dataHierarchy={'SubjectID','Session','Condition','Trial','Block'};
end

addParameter(p,'filename','',@ischar);


addOptional(p,'data',[],@(x) iscell(x) || isa(x, 'exploreFNIRS.core.Experiment')); % Cell of FNIRS structs, or an Experiment object
addOptional(p,'timeShiftTo0',ExFNIRS.settings.timeShiftTo0,@islogical); %Specifies whether to automatically shift the start of the FNIRS period to 0, 
		%best practice though is to turn this off and do it yourself before hand so that task starts at 0s and the baseline is before/after/during. See setT0fnirs()
addOptional(p,'blStart', ExFNIRS.settings.baseline_start,validScalarNum);  %Time at which baseline starts (absolute)
addOptional(p,'blEnd',ExFNIRS.settings.baseline_end,validScalarNum);	%Time at which baseline ends (absolute)
addOptional(p,'blockStart',ExFNIRS.settings.block_start,validScalarNum); %Time at which block or task starts (absolute)
addOptional(p,'blockEnd',ExFNIRS.settings.block_end,validScalarNum); %Time at which block or task ends (absolute)
addOptional(p,'plotStart',ExFNIRS.settings.plot_start,validScalarNum); %Default parameter for lower xlimit on plots (affects which models are displayed in barcharts and which timepoints are included)
addOptional(p,'plotEnd',ExFNIRS.settings.plot_end,validScalarNum); %Default parameter for upper xlimit on plots (see above note)
addOptional(p,'barSegmentLength', ExFNIRS.settings.barchart_resample_size,validScalarPosNum); %Default averaging/binning period for barcharts AND relevant export information  
addOptional(p,'resampleSize',nan,validScalarPosNum); % ExFNIRS.settings.grandavg_resample_size, used for resampling

parse(p,varargin{:});

% Detect Experiment object and extract data + settings
inputData = p.Results.data;
experimentSource = [];

if isa(inputData, 'exploreFNIRS.core.Experiment')
    experimentSource = inputData;
    inputData = experimentSource.data;

    % Map Experiment settings → ExFNIRS settings
    exS = experimentSource.settings;
    ExFNIRS.settings.baseline_start = exS.baseline(1);
    ExFNIRS.settings.baseline_end = exS.baseline(2);
    ExFNIRS.settings.block_start = exS.taskStart;
    ExFNIRS.settings.use_baseline = exS.useBaseline;
    ExFNIRS.settings.timeShiftTo0 = false;
    ExFNIRS.dataHierarchy = experimentSource.hierarchy;

    if exS.barBinSize > 0
        ExFNIRS.settings.barchart_resample_size = exS.barBinSize;
    else
        % barBinSize=0 means full task window; derive from task duration
        ExFNIRS.settings.barchart_resample_size = -1; % placeholder, resolved below
    end
    if exS.resampleRate > 0
        ExFNIRS.settings.grandavg_resample_size = exS.resampleRate;
    end

    % Map avgMode → within_sub_avg_mode popup index
    switch lower(exS.avgMode)
        case 'none',      ExFNIRS.settings.within_sub_avg_mode = 1;
        case 'flat',      ExFNIRS.settings.within_sub_avg_mode = 2;
        case 'hierarchy', ExFNIRS.settings.within_sub_avg_mode = 3;
    end

    fprintf('Loaded Experiment object (%d segments)\n', length(inputData));
end

if ~isempty(inputData) || ~isfield(ExFNIRS, 'data')
    ExFNIRS.data = inputData;
    if size(ExFNIRS.data,2) > size(ExFNIRS.data,1)
        ExFNIRS.data = ExFNIRS.data';
    end
elseif ~isempty(p.Results.filename)
    exploreFNIRS.loadEx(p.Results.filename);
end






if isempty(experimentSource)
    ExFNIRS.settings.baseline_start=p.Results.blStart;
    ExFNIRS.settings.baseline_end=p.Results.blEnd;
    ExFNIRS.settings.block_start=p.Results.blockStart;
    ExFNIRS.settings.block_end=p.Results.blockEnd;
    ExFNIRS.settings.plot_start=p.Results.plotStart;
    ExFNIRS.settings.plot_end=p.Results.plotEnd;
    ExFNIRS.settings.barchart_resample_size=p.Results.barSegmentLength;
    ExFNIRS.settings.grandavg_resample_size=p.Results.resampleSize;
else
    % Use Experiment taskEnd if set, otherwise derive from data
    exS = experimentSource.settings;
    if isfinite(exS.taskEnd)
        ExFNIRS.settings.block_end = exS.taskEnd;
    else
        firstSeg = ExFNIRS.data{1};
        if isfield(firstSeg, 'time') && ~isempty(firstSeg.time)
            ExFNIRS.settings.block_end = max(firstSeg.time);
        end
    end
    % Derive bar bin size from task window if not explicitly set
    if ExFNIRS.settings.barchart_resample_size <= 0
        ExFNIRS.settings.barchart_resample_size = ...
            ExFNIRS.settings.block_end - ExFNIRS.settings.block_start;
    end
    ExFNIRS.settings.plot_start = min(0, ExFNIRS.settings.block_start);
    ExFNIRS.settings.plot_end = ExFNIRS.settings.block_end;
end



segInfoVars={'Session','Trial','Block','Condition','Time'};
randFxStr{1}='1|SubjectID';
for i=2:2:length(segInfoVars)*2
   randFxStr{i}=sprintf('%s|SubjectID',segInfoVars{(i)/2}); 
   randFxStr{i+1}=sprintf('-1+%s|SubjectID',segInfoVars{(i)/2}); 
end

set(handles.popupmenu_lmer_randomeffects,'String',randFxStr);
ExFNIRS.settings.LME_randomFxStrs=randFxStr;

if(ExFNIRS.settings.processRaw)
    set(handles.listbox_raw_methods,'Enable','on');
else
    set(handles.listbox_raw_methods,'Enable','off');
    set(handles.listbox_raw_methods,'Value',1);
end




if(isempty(ExFNIRS.settings.plot_start))
   ExFNIRS.settings.plot_start=min(0,ExFNIRS.settings.block_start);
end

if(isempty(ExFNIRS.settings.plot_end))
   ExFNIRS.settings.plot_end=ExFNIRS.settings.block_end;
end



if ~isempty(experimentSource)
    % Set GUI widgets to match Experiment-provided values
    set(handles.popupmenu_within_sub_avg,'Value', ExFNIRS.settings.within_sub_avg_mode);
    set(handles.checkbox_usebaseline,'Value', ExFNIRS.settings.use_baseline);
else
    ExFNIRS.settings.within_sub_avg_mode=get(handles.popupmenu_within_sub_avg,'Value');
    ExFNIRS.settings.timeShiftTo0=p.Results.timeShiftTo0;
end

set(handles.listbox_hierarchy,'String',ExFNIRS.dataHierarchy(2:end));

set(handles.edit_baseline_start,'String',sprintf('%.2f',ExFNIRS.settings.baseline_start));
set(handles.edit_baseline_end,'String',sprintf('%.2f',ExFNIRS.settings.baseline_end));
set(handles.edit_block_start,'String',sprintf('%.2f',ExFNIRS.settings.block_start));
set(handles.edit_block_end,'String',sprintf('%.2f',ExFNIRS.settings.block_end));
set(handles.edit_plot_start,'String',sprintf('%.2f',ExFNIRS.settings.plot_start));
set(handles.edit_plot_end,'String',sprintf('%.2f',ExFNIRS.settings.plot_end));
set(handles.edit_barchart_resample_size,'String',sprintf('%.2f',ExFNIRS.settings.barchart_resample_size));

set(handles.checkbox_process_raw,'Value',ExFNIRS.settings.processRaw);
strs=get(handles.popupmenu_info_group,'String');
val=get(handles.popupmenu_info_group,'Value');
if(~iscell(strs))
    selStr=strs;
else
    selStr=strs{val};
end
ExFNIRS.settings.curInfoGroup=selStr;



strs=get(handles.popupmenu_groupby_info_field,'String');
val=get(handles.popupmenu_groupby_info_field,'Value');

if(~iscell(strs))
    selStr=strs;
else
    selStr=strs{val};
end

ExFNIRS.settings.curInfoGroupBy=selStr;


if(isempty(ExFNIRS.data))
    error('Must supply data!');
end



initializeGUIvalues(handles);



% UIWAIT makes exploreFNIRS wait for user response (see UIRESUME)
% uiwait(handles.figure1);


function menu_import_file_Callback(handles)
% Import a single fNIRS file and open a new exploreFNIRS instance
try
    data = pf2.import.import();
catch ME
    errordlg(ME.message, 'Import Error');
    return;
end
if isempty(data), return; end
if isstruct(data), data = {data}; end
exploreFNIRS(data);

function menu_import_dir_Callback(handles)
% Import a directory of fNIRS files and open a new exploreFNIRS instance
dirPath = uigetdir('', 'Select fNIRS Data Directory');
if isequal(dirPath, 0), return; end
try
    data = pf2.import.import(dirPath);
catch ME
    errordlg(ME.message, 'Import Error');
    return;
end
if isempty(data), return; end
if isstruct(data), data = {data}; end
exploreFNIRS(data);

function PopulateGUIfields(dataTable,handles)

global ExFNIRS

fieldNames={'SubjectID','Group','Subgroup','Session','Trial','Condition','Block'};
defaultFields={'Group','Condition'};

for f = 1:length(fieldNames)

    uItems=unique(dataTable.(fieldNames{f}));
    lowerNamePart=fieldNames{f};
    lowerNamePart(1)=lower(lowerNamePart(1));

    listboxName=sprintf('listbox_%s',lowerNamePart);
    checkboxName=sprintf('checkbox_%s_plotby',lowerNamePart);

    set(handles.(listboxName),'String',uItems);
    set(handles.(listboxName),'Value',1:length(uItems));

    if(length(uItems)<=1)
        set(handles.(listboxName),'Enable','off');

        if(~strcmp(checkboxName,'checkbox_subgroup_plotby'))
            set(handles.(checkboxName),'Enable','off');
            set(handles.(checkboxName),'Value',0);
        end
        ExFNIRS.settings.plotby.(fieldNames{f})=0;
    else
        set(handles.(listboxName),'Enable','on');
        if(~strcmp(checkboxName,'checkbox_subgroup_plotby'))
            set(handles.(checkboxName),'Enable','on');
            set(handles.(checkboxName),'Value',ismember(fieldNames{f},defaultFields));
        else
            set(handles.checkbox_group_plotby,'Enable','on');
        end
        ExFNIRS.settings.plotby.(fieldNames{f})=ismember(fieldNames{f},defaultFields);
    end

end


curRawMethods=processFNIRS2_configureMethods('currentRawMethodsCallback',1,[],handles);
if(~isempty(curRawMethods))
   set(handles.listbox_raw_methods,'String',curRawMethods); 
end
curOxyMethods=processFNIRS2_configureMethods('currentOxyMethodsCallback',1,[],handles);
if(~isempty(curOxyMethods))
   set(handles.listbox_oxy_methods,'String',curOxyMethods); 
end

setExChannelMode('ROI',handles,true)%initialize ROI fields
setExChannelMode('fNIR',handles,true);



% --- Outputs from this function are returned to the command line.
function varargout = exploreFNIRS_OutputFcn(hObject, eventdata, handles)
% varargout  cell array for returning output args (see VARARGOUT);
% hObject    handle to figure
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Get default command line output from handles structure
varargout{1} = handles.output;




% --------------------------------------------------------------------
function initialize_gui(fig_handle, handles, isreset)
% If the metricdata field is present and the reset flag is false, it means
% we are we are just re-initializing a GUI by calling it from the cmd line
% while it is up. So, bail out as we dont want to reset the data.


% Update handles structure
guidata(handles.figure1, handles);


% --- Executes on selection change in listbox_subjectID.
function listbox_subjectID_Callback(hObject, eventdata, handles)
% hObject    handle to listbox_subjectID (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: contents = cellstr(get(hObject,'String')) returns listbox_subjectID contents as cell array
%        contents{get(hObject,'Value')} returns selected item from listbox_subjectID

global ExFNIRS

if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(true,handles);
end

function flagForUpdate(UpdateNeeded,handles)

global ExFNIRS


if(~isfield(ExFNIRS,'UpdateNeeded'))
   ExFNIRS.UpdateNeeded=3; 
end

if(UpdateNeeded>0)
    if(ExFNIRS.UpdateNeeded<UpdateNeeded)  % 1 indicates that table just needs to be arranged and averaged
        ExFNIRS.UpdateNeeded=UpdateNeeded; %2 indicates fNIRS data needs to be resampled as well
                                           % 3 indicates fNIRS must be
                                           % reprocessed entirely 
                                           %     (ie new method)
                                           % 4 indicates that entire
                                           % dataset/ data table needs to
                                           % be reproduced      
    end
    set(handles.pushbutton_process_selection,'BackgroundColor','Red');
    updateSelectedTable(handles,false);
else
    ExFNIRS.UpdateNeeded=false;
    set(handles.pushbutton_process_selection,'BackgroundColor','Green');
end

% --- Executes during object creation, after setting all properties.
function listbox_subjectID_CreateFcn(hObject, eventdata, handles)
% hObject    handle to listbox_subjectID (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: listbox controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end


% --- Executes on selection change in listbox_group.
function listbox_group_Callback(hObject, eventdata, handles)
% hObject    handle to listbox_group (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: contents = cellstr(get(hObject,'String')) returns listbox_group contents as cell array
%        contents{get(hObject,'Value')} returns selected item from listbox_group
global ExFNIRS
if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(true,handles);
end
% --- Executes during object creation, after setting all properties.
function listbox_group_CreateFcn(hObject, eventdata, handles)
% hObject    handle to listbox_group (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: listbox controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end


% --- Executes on selection change in listbox_session.
function listbox_session_Callback(hObject, eventdata, handles)
% hObject    handle to listbox_session (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: contents = cellstr(get(hObject,'String')) returns listbox_session contents as cell array
%        contents{get(hObject,'Value')} returns selected item from listbox_session
global ExFNIRS

if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(true,handles);
end

% --- Executes during object creation, after setting all properties.
function listbox_session_CreateFcn(hObject, eventdata, handles)
% hObject    handle to listbox_session (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: listbox controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end


% --- Executes on selection change in listbox_trial.
function listbox_trial_Callback(hObject, eventdata, handles)
% hObject    handle to listbox_trial (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: contents = cellstr(get(hObject,'String')) returns listbox_trial contents as cell array
%        contents{get(hObject,'Value')} returns selected item from listbox_trial
global ExFNIRS

if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(true,handles);
end

% --- Executes during object creation, after setting all properties.
function listbox_trial_CreateFcn(hObject, eventdata, handles)
% hObject    handle to listbox_trial (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: listbox controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end


% --- Executes on selection change in listbox_condition.
function listbox_condition_Callback(hObject, eventdata, handles)
% hObject    handle to listbox_condition (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: contents = cellstr(get(hObject,'String')) returns listbox_condition contents as cell array
%        contents{get(hObject,'Value')} returns selected item from listbox_condition
global ExFNIRS

if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(true,handles);
end

% --- Executes during object creation, after setting all properties.
function listbox_condition_CreateFcn(hObject, eventdata, handles)
% hObject    handle to listbox_condition (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: listbox controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end


% --- Executes on button press in pushbutton_group_select_all.
function pushbutton_group_select_all_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_group_select_all (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

global ExFNIRS

if(ExFNIRS.settings.use_group)
    strs=get(handles.listbox_group,'String');
    if(iscell(strs)||ismatrix(strs))
        set(handles.listbox_group,'Value',[1:size(strs,1)]);
    end
else
    strs=get(handles.listbox_subgroup,'String');
    if(iscell(strs)||ismatrix(strs))
        set(handles.listbox_subgroup,'Value',[1:size(strs,1)]);
    end
end



if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(true,handles);
end

% --- Executes on button press in pushbutton_group_select_none.
function pushbutton_group_select_none_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_group_select_none (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)
global ExFNIRS
if(ExFNIRS.settings.use_group)
    set(handles.listbox_group,'Value',[]);
else
    set(handles.listbox_subgroup,'Value',[]);
end
% --- Executes on button press in pushbutton_session_select_all.
function pushbutton_session_select_all_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_session_select_all (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

strs=get(handles.listbox_session,'String');
if(iscell(strs)||ismatrix(strs))
    set(handles.listbox_session,'Value',[1:size(strs,1)]);
end

global ExFNIRS

if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(true,handles);
end


% --- Executes on button press in pushbutton_session_select_none.
function pushbutton_session_select_none_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_session_select_none (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)
set(handles.listbox_session,'Value',[]);

% --- Executes on button press in pushbutton_trial_select_all.
function pushbutton_trial_select_all_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_trial_select_all (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

strs=get(handles.listbox_trial,'String');
if(iscell(strs)||ismatrix(strs))
    set(handles.listbox_trial,'Value',[1:size(strs,1)]);
end

global ExFNIRS

if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(true,handles);
end

% --- Executes on button press in pushbutton_trial_select_none.
function pushbutton_trial_select_none_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_trial_select_none (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)
set(handles.listbox_trial,'Value',[]);

% --- Executes on button press in pushbutton_condition_select_all.
function pushbutton_condition_select_all_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_condition_select_all (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

strs=get(handles.listbox_condition,'String');
if(iscell(strs)||ismatrix(strs))
    set(handles.listbox_condition,'Value',[1:size(strs,1)]);
end

global ExFNIRS

if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(true,handles);
end


% --- Executes on button press in pushbutton_condition_select_none.
function pushbutton_condition_select_none_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_condition_select_none (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)
set(handles.listbox_condition,'Value',[]);



% --- Executes on button press in pushbutton_subjectID_select_all.
function pushbutton_subjectID_select_all_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_subjectID_select_all (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

strs=get(handles.listbox_subjectID,'String');
if(iscell(strs)||ismatrix(strs))
    set(handles.listbox_subjectID,'Value',[1:size(strs,1)]);
end

global ExFNIRS

if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(true,handles);
end

% --- Executes on button press in pushbutton_subjectID_select_none.
function pushbutton_subjectID_select_none_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_subjectID_select_none (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

set(handles.listbox_subjectID,'Value',[]);



function edit_baseline_start_Callback(hObject, eventdata, handles)
% hObject    handle to edit_baseline_start (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: get(hObject,'String') returns contents of edit_baseline_start as text
%        str2double(get(hObject,'String')) returns contents of edit_baseline_start as a double

global ExFNIRS
ExFNIRS.settings.baseline_start=str2num(get(handles.edit_baseline_start,'String'));
set(handles.edit_baseline_start,'String',sprintf('%.2f',ExFNIRS.settings.baseline_start));

if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(2,handles);
end

exploreFNIRS.plotExTimeline();



% --- Executes during object creation, after setting all properties.
function edit_baseline_start_CreateFcn(hObject, eventdata, handles)
% hObject    handle to edit_baseline_start (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: edit controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end



function edit_baseline_end_Callback(hObject, eventdata, handles)
% hObject    handle to edit_baseline_end (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: get(hObject,'String') returns contents of edit_baseline_end as text
%        str2double(get(hObject,'String')) returns contents of edit_baseline_end as a double
global ExFNIRS
ExFNIRS.settings.baseline_end=str2num(get(handles.edit_baseline_end,'String'));
set(handles.edit_baseline_end,'String',sprintf('%.2f',ExFNIRS.settings.baseline_end));

if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(2,handles);
end

exploreFNIRS.plotExTimeline();


% --- Executes during object creation, after setting all properties.
function edit_baseline_end_CreateFcn(hObject, eventdata, handles)
% hObject    handle to edit_baseline_end (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: edit controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end


function edit_block_start_Callback(hObject, eventdata, handles)
% hObject    handle to edit_block_start (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: get(hObject,'String') returns contents of edit_block_start as text
%        str2double(get(hObject,'String')) returns contents of edit_block_start as a double

global ExFNIRS
ExFNIRS.settings.block_start=str2num(get(handles.edit_block_start,'String'));
set(handles.edit_block_start,'String',sprintf('%.2f',ExFNIRS.settings.block_start));

syncBlockSettingsUI(handles);
exploreFNIRS.plotExTimeline();


if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(2,handles);
end


% --- Executes during object creation, after setting all properties.
function edit_block_start_CreateFcn(hObject, eventdata, handles)
% hObject    handle to edit_block_start (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: edit controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end



function edit_block_end_Callback(hObject, eventdata, handles)
% hObject    handle to edit_block_end (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: get(hObject,'String') returns contents of edit_block_end as text
%        str2double(get(hObject,'String')) returns contents of edit_block_end as a double

global ExFNIRS
ExFNIRS.settings.block_end=str2num(get(handles.edit_block_end,'String'));
set(handles.edit_block_end,'String',sprintf('%.2f',ExFNIRS.settings.block_end));

syncBlockSettingsUI(handles);
exploreFNIRS.plotExTimeline();

% --- Executes during object creation, after setting all properties.
function edit_block_end_CreateFcn(hObject, eventdata, handles)
% hObject    handle to edit_block_end (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: edit controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end



function edit_plot_start_Callback(hObject, eventdata, handles)
% hObject    handle to edit_plot_start (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: get(hObject,'String') returns contents of edit_plot_start as text
%        str2double(get(hObject,'String')) returns contents of edit_plot_start as a double

global ExFNIRS
ExFNIRS.settings.plot_start=str2num(get(handles.edit_plot_start,'String'));
set(handles.edit_plot_start,'String',sprintf('%.2f',ExFNIRS.settings.plot_start));
exploreFNIRS.plotExTimeline();


% --- Executes during object creation, after setting all properties.
function edit_plot_start_CreateFcn(hObject, eventdata, handles)
% hObject    handle to edit_plot_start (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: edit controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end



function edit_plot_end_Callback(hObject, eventdata, handles)
% hObject    handle to edit_plot_end (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: get(hObject,'String') returns contents of edit_plot_end as text
%        str2double(get(hObject,'String')) returns contents of edit_plot_end as a double

global ExFNIRS
ExFNIRS.settings.plot_end=str2num(get(handles.edit_plot_end,'String'));
set(handles.edit_plot_end,'String',sprintf('%.2f',ExFNIRS.settings.plot_end));
exploreFNIRS.plotExTimeline();

% --- Executes during object creation, after setting all properties.
function edit_plot_end_CreateFcn(hObject, eventdata, handles)
% hObject    handle to edit_plot_end (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: edit controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end



function edit_barchart_resample_size_Callback(hObject, eventdata, handles)
% hObject    handle to edit_barchart_resample_size (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: get(hObject,'String') returns contents of edit_barchart_resample_size as text
%        str2double(get(hObject,'String')) returns contents of edit_barchart_resample_size as a double

global ExFNIRS
ExFNIRS.settings.barchart_resample_size=str2num(get(handles.edit_barchart_resample_size,'String'));
set(handles.edit_barchart_resample_size,'String',sprintf('%.2f',ExFNIRS.settings.barchart_resample_size));

if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(2,handles);
end

exploreFNIRS.plotExTimeline();



% --- Executes during object creation, after setting all properties.
function edit_barchart_resample_size_CreateFcn(hObject, eventdata, handles)
% hObject    handle to edit_barchart_resample_size (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: edit controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end



% --- Executes on selection change in listbox_optode.
function listbox_optode_Callback(hObject, eventdata, handles)
% hObject    handle to listbox_optode (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: contents = cellstr(get(hObject,'String')) returns listbox_optode contents as cell array
%        contents{get(hObject,'Value')} returns selected item from listbox_optode


% --- Executes during object creation, after setting all properties.
function listbox_optode_CreateFcn(hObject, eventdata, handles)
% hObject    handle to listbox_optode (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: listbox controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end


% --- Executes on button press in pushbutton_optodes_select_all.
function pushbutton_optodes_select_all_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_optodes_select_all (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

strs=get(handles.listbox_optode,'String');
if(iscell(strs)||ismatrix(strs))
    set(handles.listbox_optode,'Value',[1:size(strs,1)]);
end

% --- Executes on button press in pushbutton_optodes_select_none.
function pushbutton_optodes_select_none_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_optodes_select_none (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

set(handles.listbox_optode,'Value',[]);

% --- Executes on selection change in listbox_biomarker.
function listbox_biomarker_Callback(hObject, eventdata, handles)
% hObject    handle to listbox_biomarker (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: contents = cellstr(get(hObject,'String')) returns listbox_biomarker contents as cell array
%        contents{get(hObject,'Value')} returns selected item from listbox_biomarker


% --- Executes during object creation, after setting all properties.
function listbox_biomarker_CreateFcn(hObject, eventdata, handles)
% hObject    handle to listbox_biomarker (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: listbox controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end



function updateSelectedTable(handles,processDataNow)

if(nargin<2)
    processDataNow=true;
else
    processDataNow=false;
end

global ExFNIRS

pf2_base.closeProgressHandles();

ExFNIRS.selectedTable=table();
ExFNIRS.selectedFNIR=cell(0);
ExFNIRS.selectedIdx=[];

strs=string(get(handles.listbox_subjectID,'String'));
selectedStrs=get(handles.listbox_subjectID,'Value');
selectedSubs=strs(selectedStrs,:);
if(isnumeric(ExFNIRS.dataTable.('SubjectID')))
    selectedSubs=str2num(char(selectedSubs));
else
   if(~iscell(selectedSubs)&&~isstring(selectedSubs))
       selectedSubs={selectedSubs};
   end
   
   missingIdx=strcmp('Missing',selectedSubs);
   %selectedSubs(missingIdx)={''};
end
selSubIdx=ismember(ExFNIRS.dataTable.('SubjectID'),selectedSubs);

strs=string(get(handles.listbox_condition,'String'));
selectedStrs=get(handles.listbox_condition,'Value')';
selectedCondition=strs(selectedStrs,:);
if(ismember('Condition',ExFNIRS.dataTable.Properties.VariableNames))
    if(isnumeric(ExFNIRS.dataTable.('Condition')))
        selectedCondition=str2num(char(selectedCondition));
        else
           if(~iscell(selectedCondition)&&~isstring(selectedCondition))
               selectedCondition={selectedCondition};
           end
           
           missingIdx=strcmp('Missing',selectedCondition);
           %selectedCondition(missingIdx)={''};
    end
    selConditionIdx=ismember(ExFNIRS.dataTable.('Condition'),selectedCondition);
else
    selConditionIdx=true([height(ExFNIRS.dataTable),1]);
end

strs=string(get(handles.listbox_session,'String'));
selectedStrs=get(handles.listbox_session,'Value')';
selectedSession=strs(selectedStrs,:);
if(isnumeric(ExFNIRS.dataTable.('Session')))
    selectedSession=str2num(char(selectedSession));
else
   if(~iscell(selectedSession)&&~isstring(selectedSession))
       selectedSession={selectedSession};
   end
   
   missingIdx=strcmp('Missing',selectedSession);
   %selectedSession(missingIdx)={''};
end
selSessionIdx=ismember(ExFNIRS.dataTable.('Session'),selectedSession);

strs=string(get(handles.listbox_block,'String'));
selectedStrs=get(handles.listbox_block,'Value')';

selectedBlock=strs(selectedStrs,:);
if(ismember('Block',ExFNIRS.dataTable.Properties.VariableNames))
    if(isnumeric(ExFNIRS.dataTable.('Block')))
        
        selectedBlock=str2num(char(selectedBlock));
    else
       if(~iscell(selectedBlock)&&~isstring(selectedBlock))
           selectedBlock={selectedBlock};
       end
       
       missingIdx=strcmp('Missing',selectedBlock);
       %selectedBlock(missingIdx)={''};
    end
    selBlockIdx=ismember(ExFNIRS.dataTable.('Block'),selectedBlock);
else
    selBlockIdx=true([height(ExFNIRS.dataTable),1]);
end

if(ExFNIRS.settings.use_group)
    strs=string(get(handles.listbox_group,'String'));
    selectedStrs=get(handles.listbox_group,'Value')';
    selectedGroup=strs(selectedStrs,:);
    if(isnumeric(ExFNIRS.dataTable.('Group')))
        selectedGroup=str2num(char(selectedGroup));
    else
       if(~isempty(selectedGroup)&&~iscell(selectedGroup)&&~isstring(selectedGroup))
           selectedGroup={selectedGroup};
       end

       missingIdx=strcmp('Missing',selectedGroup);
       %selectedGroup(missingIdx)={''};
    end
    selGroupIdx=ismember(ExFNIRS.dataTable.('Group'),selectedGroup);
else
    strs=get(handles.listbox_subgroup,'String');
    selectedStrs=get(handles.listbox_subgroup,'Value')';
    selectedGroup=strs(selectedStrs,:);
    if(isnumeric(ExFNIRS.dataTable.('Subgroup')))
        selectedGroup=str2num(char(selectedGroup));
    else
       if(~isempty(selectedGroup)&&~iscell(selectedGroup)&&~isstring(selectedGroup))
           selectedGroup={selectedGroup};
       end

       missingIdx=strcmp('Missing',selectedGroup);
       %selectedGroup(missingIdx)={''};
    end
    selGroupIdx=ismember(ExFNIRS.dataTable.('Subgroup'),selectedGroup);
end

strs=string(get(handles.listbox_trial,'String'));
selectedStrs=get(handles.listbox_trial,'Value')';
selectedTrial=strs(selectedStrs,:);
if(isnumeric(ExFNIRS.dataTable.('Trial')))
    selectedTrial=str2num(char(selectedTrial));
else
   if(~iscell(selectedTrial)&&~isstring(selectedTrial))
       selectedTrial={selectedTrial};
   end
   
   missingIdx=strcmp('Missing',selectedTrial);
   selectedTrial(missingIdx)={''};
end
selTrialIdx=ismember(ExFNIRS.dataTable.('Trial'),selectedTrial);

if(ExFNIRS.settings.use_info)
    cInfoGBYstring=ExFNIRS.settings.curInfoGroupBy;
    strs=string(get(handles.listbox_info_groupby,'String'));
    selectedStrs=get(handles.listbox_info_groupby,'Value');
    selectedInfoG=strs(selectedStrs,:);
    if(isnumeric(ExFNIRS.dataTable{1,cInfoGBYstring}))
        
        selInfoGIdx=ismember(ExFNIRS.settings.curInfoGroupByIdx,selectedStrs);
    else
        selInfoGIdx=ismember(ExFNIRS.dataTable.(cInfoGBYstring),selectedInfoG);
    end
end

sellFullIdx=selSubIdx&selConditionIdx&selSessionIdx&selBlockIdx&selGroupIdx&selTrialIdx;

if(ExFNIRS.settings.use_info)
    sellFullIdx=sellFullIdx&selInfoGIdx;
end

if(~any(sellFullIdx))
    statusTextStr='No data matching selection';
    ExFNIRS.statusGroupByStr='Ungrouped';
    set(handles.text_status_text,'String',statusTextStr);
    set(handles.text_status,'String','0 Segments in\n0 Group(s)');
    set(handles.popupmenu_info_group,'String',{''});
    return
end

ExFNIRS.selectedTable=ExFNIRS.dataTable(sellFullIdx,:);

ExFNIRS.selectedIdx=sellFullIdx;

subColIdx=find(strcmp('SubjectID',ExFNIRS.dataTable.Properties.VariableNames));
groupColIdx=find(strcmp('Group',ExFNIRS.dataTable.Properties.VariableNames));
subgroupColIdx=find(strcmp('Subgroup',ExFNIRS.dataTable.Properties.VariableNames));
sessionColIdx=find(strcmp('Session',ExFNIRS.dataTable.Properties.VariableNames));
conditionColIdx=find(strcmp('Condition',ExFNIRS.dataTable.Properties.VariableNames));
trialColIdx=find(strcmp('Trial',ExFNIRS.dataTable.Properties.VariableNames));
blockColIdx=find(strcmp('Block',ExFNIRS.dataTable.Properties.VariableNames));

if(~isfield(ExFNIRS.settings,'plotby')||isempty(ExFNIRS.settings.plotby))
    initializeGUIvalues(handles);
    
end

if(ExFNIRS.settings.use_group)
    gPlotByGroup=[ExFNIRS.settings.plotby.Group,0];
else
    gPlotByGroup=[0,ExFNIRS.settings.plotby.Group];
end

groubbyIdxEnable=[ExFNIRS.settings.plotby.SubjectID,ExFNIRS.settings.plotby.Group&&ExFNIRS.settings.use_group,ExFNIRS.settings.plotby.Group&&~ExFNIRS.settings.use_group,...
    ExFNIRS.settings.plotby.Session,ExFNIRS.settings.plotby.Condition,ExFNIRS.settings.plotby.Trial,ExFNIRS.settings.plotby.Block];
groupbyIdx=[subColIdx,groupColIdx,subgroupColIdx,sessionColIdx,conditionColIdx,trialColIdx,blockColIdx].*groubbyIdxEnable;
groupbyIdx=groupbyIdx(groupbyIdx>0);

if(ExFNIRS.settings.plotby.InfoGroupBy)
    groupbyIdx=[groupbyIdx,find(strcmp(cInfoGBYstring,ExFNIRS.dataTable.Properties.VariableNames))];
end

[groupbyRows,ia,gbyIdx]=unique(ExFNIRS.selectedTable(:,groupbyIdx));

processMinTime=min([ExFNIRS.settings.baseline_start,ExFNIRS.settings.block_start,ExFNIRS.settings.plot_start]);
processMaxTime=max([ExFNIRS.settings.baseline_end,ExFNIRS.settings.block_end,ExFNIRS.settings.plot_end]);

if(isfield(ExFNIRS,'gby'))
    rmfield(ExFNIRS,'gby');
end
ExFNIRS.gby=[];
ExFNIRS.groupByVars=groupbyRows.Properties.VariableNames;

statusTextStr='Grouping data by ';
ExFNIRS.statusGroupByStr='';
for i=1:length(ExFNIRS.groupByVars)
    statusTextStr=sprintf('%s %s X ', statusTextStr,ExFNIRS.groupByVars{i});
    if(i==1)
        ExFNIRS.statusGroupByStr=ExFNIRS.groupByVars{i};
    else
        ExFNIRS.statusGroupByStr=sprintf('%s X ', ExFNIRS.statusGroupByStr,ExFNIRS.groupByVars{i});
    end
end

statusTextStr(end-2:end)=[];
if(length(ExFNIRS.statusGroupByStr)>2)
    ExFNIRS.statusGroupByStr(end-2:end)=[];
else
    ExFNIRS.statusGroupByStr='One Group';
end


if(isempty(ExFNIRS.groupByVars))
    statusTextStr='Data is ungrouped';
    ExFNIRS.statusGroupByStr='Ungrouped';
end


set(handles.text_status_text,'String',statusTextStr);

updateInfoGroupByVars(handles);

set(handles.text_status,'String',sprintf('%i Observations in\n%i Group(s)',size(ExFNIRS.selectedTable,1),max(gbyIdx)));



if(processDataNow)
    processCurrentFunction(handles);
    
    if(~isfield(ExFNIRS,'curProcessedData')||isempty(ExFNIRS.curProcessedData))
       flagForUpdate(3,handles);
       error('No processed data yet!'); 
    end

    ExFNIRS.selectedFNIR=ExFNIRS.curProcessedData(sellFullIdx,:);
    
    
    
    
    preprocessFNIRSData();
    processSelectedTable(handles,sellFullIdx,gbyIdx);
end

function preprocessFNIRSData()
global ExFNIRS
if(ExFNIRS.UpdateNeeded==2||~isfield(ExFNIRS,'curPreprocessedFNIR'))
    exploreFNIRS.plotExTimeline();

    numSegs = size(ExFNIRS.curProcessedData, 1);
    fprintf('ExploreFNIRS - Resampling and baselining %d segments\n', numSegs);

    fNIR = ExFNIRS.curProcessedData;
    baseline = cell(size(fNIR));
    gbyFNIRS = fNIR;
    gbyFNIRS_blk = cell(size(fNIR));

    useBL    = ExFNIRS.settings.use_baseline;
    blStart  = ExFNIRS.settings.baseline_start;
    blEnd    = ExFNIRS.settings.baseline_end;
    barRS    = ExFNIRS.settings.barchart_resample_size;
    gaRS     = ExFNIRS.settings.grandavg_resample_size;
    blkStart = ExFNIRS.settings.block_start;

    [canPar, poolOn] = pf2_base.accel.canParfor();
    useParfor = canPar && poolOn && numSegs > 2;

    if useParfor
        parfor i = 1:numSegs
            if useBL
                bl = pf2.data.split(fNIR{i}, blStart, blEnd);
                baseline{i} = bl;
                gbyFNIRS_blk{i} = pf2.data.resample(fNIR{i}, barRS, ...
                    'centerOnTime', blkStart, 'timeOutMode', 'start', ...
                    'blfNIR', bl, 'averageAux', true, 'flattenAux', true, 'trimAux', false);
                rs = pf2.data.resample(fNIR{i}, gaRS, ...
                    'centerOnTime', blkStart, 'timeOutMode', 'start', ...
                    'blfNIR', bl, 'averageAux', true, 'flattenAux', true, 'trimAux', false);
                rs.time = rs.time + blkStart;
                gbyFNIRS{i} = rs;
            else
                baseline{i} = [];
                gbyFNIRS_blk{i} = pf2.data.resample(fNIR{i}, barRS, ...
                    'centerOnTime', blkStart, 'timeOutMode', 'start', ...
                    'averageAux', true, 'flattenAux', true, 'trimAux', false);
                gbyFNIRS{i} = pf2.data.resample(fNIR{i}, gaRS, ...
                    'centerOnTime', blkStart, 'timeOutMode', 'start', ...
                    'averageAux', true, 'flattenAux', true, 'trimAux', false);
            end
        end
    else
        for i = 1:numSegs
            fprintf('Resampling and baselining fNIRS %i of %i\n', i, numSegs);
            if useBL
                bl = pf2.data.split(fNIR{i}, blStart, blEnd);
                baseline{i} = bl;
                gbyFNIRS_blk{i} = pf2.data.resample(fNIR{i}, barRS, ...
                    'centerOnTime', blkStart, 'timeOutMode', 'start', ...
                    'blfNIR', bl, 'averageAux', true, 'flattenAux', true, 'trimAux', false);
                rs = pf2.data.resample(fNIR{i}, gaRS, ...
                    'centerOnTime', blkStart, 'timeOutMode', 'start', ...
                    'blfNIR', bl, 'averageAux', true, 'flattenAux', true, 'trimAux', false);
                rs.time = rs.time + blkStart;
                gbyFNIRS{i} = rs;
            else
                baseline{i} = [];
                gbyFNIRS_blk{i} = pf2.data.resample(fNIR{i}, barRS, ...
                    'centerOnTime', blkStart, 'timeOutMode', 'start', ...
                    'averageAux', true, 'flattenAux', true, 'trimAux', false);
                gbyFNIRS{i} = pf2.data.resample(fNIR{i}, gaRS, ...
                    'centerOnTime', blkStart, 'timeOutMode', 'start', ...
                    'averageAux', true, 'flattenAux', true, 'trimAux', false);
            end
        end
    end

    ExFNIRS.curPreprocessedFNIR = struct();
    ExFNIRS.curPreprocessedFNIR.fNIR = fNIR;
    ExFNIRS.curPreprocessedFNIR.baseline = baseline;
    ExFNIRS.curPreprocessedFNIR.gbyFNIRS = gbyFNIRS;
    ExFNIRS.curPreprocessedFNIR.gbyFNIRS_blk = gbyFNIRS_blk;

    ExFNIRS.UpdateNeeded = true; % mark that data was preprocessed, but not averaged into groups
else
    ExFNIRS.UpdateNeeded = true;
end

function processSelectedTable(handles,sellFullIdx,gbyIdx)
global ExFNIRS
pf2_base.closeProgressHandles();

fprintf('ExploreFNIRS - Processing Groups\n');

numSegs = size(ExFNIRS.selectedTable, 1);
numGroups = max(gbyIdx);

ExFNIRS.gbyFlat = struct();
ExFNIRS.gbyFlat.fNIR = ExFNIRS.curPreprocessedFNIR.fNIR(sellFullIdx,:);
ExFNIRS.gbyFlat.baseline = ExFNIRS.curPreprocessedFNIR.baseline(sellFullIdx,:);
ExFNIRS.gbyFlat.gbyFNIRS = ExFNIRS.curPreprocessedFNIR.gbyFNIRS(sellFullIdx,:);
ExFNIRS.gbyFlat.gbyFNIRS_blk = ExFNIRS.curPreprocessedFNIR.gbyFNIRS_blk(sellFullIdx,:);
ExFNIRS.gbyFlat.gbyIndex = gbyIdx;

% Set the mode label once (not per-group)
avgMode = ExFNIRS.settings.within_sub_avg_mode;
if avgMode == 1
    ExFNIRS.settings.within_sub_avg_mode_label = 'None';
elseif avgMode == 2
    ExFNIRS.settings.within_sub_avg_mode_label = 'Flat';
elseif avgMode == 3
    ExFNIRS.settings.within_sub_avg_mode_label = 'Hierarchy';
end

% Pre-extract per-group data into locals (can't index globals inside parfor)
grpTables    = cell(1, numGroups);
grpFNIRS     = cell(1, numGroups);
grpFNIRS_blk = cell(1, numGroups);
grpHArg      = cell(1, numGroups);
grpFlatArg   = cell(1, numGroups);
barRS        = ExFNIRS.settings.barchart_resample_size;
dataHierarchy = ExFNIRS.dataHierarchy;

for i = 1:numGroups
    grpTables{i}    = ExFNIRS.selectedTable(gbyIdx==i,:);
    grpFNIRS{i}     = ExFNIRS.gbyFlat.gbyFNIRS(gbyIdx==i,:);
    grpFNIRS_blk{i} = ExFNIRS.gbyFlat.gbyFNIRS_blk(gbyIdx==i,:);

    missMask = grpTables{i}.missingFNIRS == 1;

    if avgMode == 1
        grpHArg{i} = [];
    elseif avgMode == 2
        grpHArg{i} = grpTables{i}(~missMask, 'SubjectID');
    elseif avgMode == 3
        grpHArg{i} = grpTables{i}(~missMask, dataHierarchy);
    end
    grpFlatArg{i} = grpTables{i}(~missMask, 'SubjectID');
end

% Grand averaging (parallel when pool available)
gbyGrand        = cell(1, numGroups);
gbyGrandBar     = cell(1, numGroups);
gbyGrandBarFlat = cell(1, numGroups);

[canPar, poolOn] = pf2_base.accel.canParfor();
useParfor = canPar && poolOn && numGroups > 1;

if useParfor
    parfor i = 1:numGroups
        missMask = grpTables{i}.missingFNIRS == 1;
        gbyGrand{i}        = grandAvgFNIRS(grpFNIRS{i}(~missMask), false, [], false, grpHArg{i}, false, true);
        gbyGrandBar{i}     = grandAvgFNIRS(grpFNIRS_blk{i}(~missMask), false, barRS, false, grpHArg{i}, false, true);
        gbyGrandBarFlat{i} = grandAvgFNIRS(grpFNIRS_blk{i}(~missMask), false, barRS, false, grpFlatArg{i}, false, true);
    end
else
    for i = 1:numGroups
        fprintf('Processing Group %i of %i\n', i, numGroups);
        missMask = grpTables{i}.missingFNIRS == 1;
        gbyGrand{i}        = grandAvgFNIRS(grpFNIRS{i}(~missMask), false, [], false, grpHArg{i}, false, true);
        gbyGrandBar{i}     = grandAvgFNIRS(grpFNIRS_blk{i}(~missMask), false, barRS, false, grpHArg{i}, false, true);
        gbyGrandBarFlat{i} = grandAvgFNIRS(grpFNIRS_blk{i}(~missMask), false, barRS, false, grpFlatArg{i}, false, true);
    end
end

% Write back to ExFNIRS.gby
for i = 1:numGroups
    ExFNIRS.gby(i).gbyTables      = grpTables{i};
    ExFNIRS.gby(i).gbyFNIRS       = grpFNIRS{i};
    ExFNIRS.gby(i).gbyFNIRS_blk   = grpFNIRS_blk{i};
    ExFNIRS.gby(i).gbyGrand       = gbyGrand{i};
    ExFNIRS.gby(i).gbyGrandBar    = gbyGrandBar{i};
    ExFNIRS.gby(i).gbyGrandBarFlat = gbyGrandBarFlat{i};
end

set(handles.text_status, 'String', sprintf('%i Segments in\n%i Group(s)', numSegs, numGroups));

flagForUpdate(false, handles);


function updateInfoGroupByVars(handles)
global ExFNIRS

plotInfoVars=cell(length(ExFNIRS.groupByVars)+1,1);
plotInfoVars{1}='';
plotInfoVars(2:end,1)=ExFNIRS.groupByVars;
set(handles.popupmenu_info_group,'String',plotInfoVars);


[a,b]=ismember(ExFNIRS.settings.curInfoGroup,plotInfoVars);

if(a==1)
   set(handles.popupmenu_info_group,'Value',b);
else
    set(handles.popupmenu_info_group,'Value',1);
end

function processCurrentFunction(handles)

global ExFNIRS

if(ExFNIRS.UpdateNeeded==4) % 4 indicates that everything needs to be changed
    error('Dataset has been updated, please close and repoen ExFNIRS');
end

if(ExFNIRS.UpdateNeeded==3) % 3 indicates that data needs to be reprocessed

strsRaw=get(handles.listbox_raw_methods,'String');
selectedStrs=get(handles.listbox_raw_methods,'Value');
cur_raw_method=strsRaw(selectedStrs,:);

strsOxy=get(handles.listbox_oxy_methods,'String');
selectedStrs=get(handles.listbox_oxy_methods,'Value');
cur_oxy_method=strsOxy(selectedStrs,:);

if(~isfield(ExFNIRS,'processedData'))
    ExFNIRS.processedData=cell(length(strsOxy)*length(strsRaw),3);
    ExFNIRS.numProcessed=0;
end

if(ExFNIRS.settings.processRaw)
    exploreFNIRS.processMethods(cur_raw_method,cur_oxy_method);
else
    exploreFNIRS.processMethods([],cur_oxy_method);
end

[strsOxy,iOxy]=pf2.methods.oxy();
[strsRaw,iRaw]=pf2.methods.raw();

set(handles.listbox_oxy_methods,'String',strsOxy);
set(handles.listbox_oxy_methods,'Value',find(iOxy));
set(handles.listbox_raw_methods,'String',strsRaw);
set(handles.listbox_raw_methods,'Value',find(iRaw));

% Refresh optode list from processed data
if isfield(ExFNIRS,'currentOpt') && ~isempty(ExFNIRS.currentOpt) ...
        && strcmp(ExFNIRS.settings.ChannelMode,'fNIR')
    if isfield(ExFNIRS,'currentOptLabels') && ~isempty(ExFNIRS.currentOptLabels)
        set(handles.listbox_optode,'String',ExFNIRS.currentOptLabels);
    else
        set(handles.listbox_optode,'String',ExFNIRS.currentOpt);
    end
    set(handles.listbox_optode,'Value',1:length(ExFNIRS.currentOpt));
end

ExFNIRS.UpdateNeeded=2; % 2 indicates that data needs to be resampled

end

% --- Executes on button press in pushbutton_biomarker_select_all.
function pushbutton_biomarker_select_all_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_biomarker_select_all (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

strs=get(handles.listbox_biomarker,'String');
if(iscell(strs)||ismatrix(strs))
    set(handles.listbox_biomarker,'Value',[1:size(strs,1)]);
end

% --- Executes on button press in pushbutton_biomarker_select_none.
function pushbutton_biomarker_select_none_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_biomarker_select_none (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

set(handles.listbox_biomarker,'Value',[]);


% --- Executes on selection change in listbox_raw_methods.
function listbox_raw_methods_Callback(hObject, eventdata, handles)
% hObject    handle to listbox_raw_methods (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: contents = cellstr(get(hObject,'String')) returns listbox_raw_methods contents as cell array
%        contents{get(hObject,'Value')} returns selected item from listbox_raw_methods
global ExFNIRS

if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(3,handles);
end

% --- Executes during object creation, after setting all properties.
function listbox_raw_methods_CreateFcn(hObject, eventdata, handles)
% hObject    handle to listbox_raw_methods (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: listbox controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end


% --- Executes on selection change in listbox_oxy_methods.
function listbox_oxy_methods_Callback(hObject, eventdata, handles)
% hObject    handle to listbox_oxy_methods (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: contents = cellstr(get(hObject,'String')) returns listbox_oxy_methods contents as cell array
%        contents{get(hObject,'Value')} returns selected item from listbox_oxy_methods
global ExFNIRS

if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(3,handles);
end


% --- Executes during object creation, after setting all properties.
function listbox_oxy_methods_CreateFcn(hObject, eventdata, handles)
% hObject    handle to listbox_oxy_methods (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: listbox controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end


% --- Executes on button press in pushbutton_plot_temporal.
function pushbutton_plot_temporal_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_plot_temporal (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

global ExFNIRS

if(ExFNIRS.UpdateNeeded) 
    updateSelectedTable(handles);
end

if(~isfield(ExFNIRS,'gby'))
    warning('No groups match selection criteria');
    return;
end

exploreFNIRS.plot.temporal(ExFNIRS.gby,ExFNIRS.groupByVars,ExFNIRS.settings,handles);



function possibleStr=num2strOrNot(possibleStr)
if(iscell(possibleStr))
    for i=1:length(possibleStr)
       if(~ischar(possibleStr{i})&&isnumeric(possibleStr{i}))
            possibleStr{i}=num2str(possibleStr{i}); 
       end
    end
elseif(~ischar(possibleStr)&&isnumeric(possibleStr))
    possibleStr=num2str(possibleStr);
end


function h=xlabel_with_space(figHandle,labelstring)
if(nargin<2)
    labelstring=figHandle;
    figHandle=gca;
end

if(iscell(labelstring))
    labelstring=labelstring{1};
end

if(~isempty(labelstring))
    labelstring(labelstring=='_')=' ';
end
h=xlabel(figHandle,labelstring);

function h=ylabel_with_space(figHandle,labelstring)
if(nargin<2)
    labelstring=figHandle;
    figHandle=gca;
end

if(iscell(labelstring))
    labelstring=labelstring{1};
end

if(~isempty(labelstring))
    labelstring(labelstring=='_')=' ';
end
h=ylabel(figHandle,labelstring);

function h=title_with_space(figHandle,labelstring)
if(nargin<2)
    labelstring=figHandle;
    figHandle=gca;
end

if(~isempty(labelstring))
    labelstring(labelstring=='_')=' ';
end
h=title(figHandle,labelstring);

function h=suptitle_with_space(axHandle,labelstring)

if(nargin<2)
    labelstring=axHandle;

    if(~isempty(labelstring))
        labelstring(labelstring=='_')=' ';
    end
    h=pf2_base.external.suptitle(labelstring);
else
    if(~isempty(labelstring))
        labelstring(labelstring=='_')=' ';
    end
    h=pf2_base.external.suptitle(axHandle,labelstring);
end




    
function addDebugAnnotation(figHandle,optionalstring)
global ExFNIRS
curTime = datetime(now,'ConvertFrom','datenum');
debugString=sprintf('%s\n%s (%s)\n%s',ExFNIRS.curMethodName,ExFNIRS.statusGroupByStr,ExFNIRS.settings.within_sub_avg_mode_label,curTime);
if(nargin>1)
    debugString=sprintf('%s\n%s',debugString,optionalstring);
end

debugString(debugString==('_'))='-';
th=annotation(figHandle,'textbox',[0 0 0.1 1],'String',debugString,'FitBoxToText','on');
th.FontSize = 6;
th.LineStyle='none';
th.HorizontalAlignment='left';
th.VerticalAlignment='bottom';
curPos=th.Position;




function outStr=getFormattedTrialString(fNIR)

if(~isfield(fNIR,'info'))
    outStr='Missing Info';
    return;
end

outStr='';

subStr=num2strOrNot(fNIR.info.SubjectID);
groupStr=num2strOrNot(fNIR.info.Group);
sessionStr=num2strOrNot(fNIR.info.Session);
conditionStr=num2strOrNot(fNIR.info.Condition);
trialStr=num2strOrNot(fNIR.info.Trial);
blockStr=num2strOrNot(fNIR.info.Block);

useID=true&&~isempty(subStr);
useGroup=true&&~isempty(groupStr);
useSession=true&&~isempty(sessionStr);
useCondition=true&&~isempty(conditionStr);
useTrial=true&&~isempty(trialStr);
useBlock=true&&~isempty(blockStr);

if(useID)
    outStr=sprintf('%sSubjectID:%s\n',outStr,subStr);
end
if(useGroup)
    outStr=sprintf('%sGroup:%s\n',outStr,groupStr);
end
if(useSession)
    outStr=sprintf('%sSession:%s\n',outStr,sessionStr);
end
if(useCondition)
    outStr=sprintf('%sCondition:%s\n',outStr,conditionStr);
end
if(useTrial)
    outStr=sprintf('%sTrial:%s\n',outStr,trialStr);
end
if(useBlock)
    outStr=sprintf('%sBlock:%s\n',outStr,blockStr);
end

outStr(end)='';


  
    





% --- Executes on button press in checkbox_subjectID_plotby.
function checkbox_subjectID_plotby_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_subjectID_plotby (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_subjectID_plotby
global ExFNIRS
ExFNIRS.settings.plotby.SubjectID=get(handles.checkbox_subjectID_plotby,'Value');

if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(true,handles);
end

% --- Executes on button press in checkbox_group_plotby.
function checkbox_group_plotby_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_group_plotby (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_group_plotby
global ExFNIRS
ExFNIRS.settings.plotby.Group=get(handles.checkbox_group_plotby,'Value');
if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(true,handles);
end


% --- Executes on button press in checkbox_session_plotby.
function checkbox_session_plotby_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_session_plotby (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_session_plotby
global ExFNIRS
ExFNIRS.settings.plotby.Session=get(handles.checkbox_session_plotby,'Value');
if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(true,handles);
end


% --- Executes on button press in checkbox_trial_plotby.
function checkbox_trial_plotby_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_trial_plotby (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_trial_plotby
global ExFNIRS
ExFNIRS.settings.plotby.Trial=get(handles.checkbox_trial_plotby,'Value');
if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(true,handles);
end


% --- Executes on button press in checkbox_condition_plotby.
function checkbox_condition_plotby_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_condition_plotby (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_condition_plotby
global ExFNIRS
ExFNIRS.settings.plotby.Condition=get(handles.checkbox_condition_plotby,'Value');
if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(true,handles);
end


% --- Executes on button press in pushbutton_export_csv.
function pushbutton_export_csv_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_export_csv (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)
global ExFNIRS

if(ExFNIRS.UpdateNeeded)
    updateSelectedTable(handles);
end

if(isempty(ExFNIRS.selectedTable)||isempty(ExFNIRS.gby))
    return;
end

answerFormat = questdlg(sprintf('Select Export Table Format:\n\nWide Format: 1 row per segment, 1 column per biomarkerXchannelXtimepoint\nLong Format 1 row per timepointXsegment, 1 column per channelXbiomarker\n'), ...
	'Table Format', ...
	'Wide Format','Long Format','Cancel','Wide Format');

if strcmp(answerFormat,'Cancel')
    return
end

curTimes=[];
for i=1:length(ExFNIRS.gby)
    if(~isempty(ExFNIRS.gby(i).gbyGrandBar))
        curTimes=[curTimes;ExFNIRS.gby(i).gbyGrandBar.segmentTimes];
    end
end
curTimes=unique(curTimes,'row');

fprintf('Current Block Times:')
cTimesTable=array2table(curTimes);
cTimesTable.Properties.VariableNames={'Start','MidPoint','End'};
display(cTimesTable);



fprintf('Current Viewing Window %.1f to %.1fs\n',ExFNIRS.settings.plot_start,ExFNIRS.settings.plot_end);
fprintf('Current Task Period %.1f:s to %.1fs\n',ExFNIRS.settings.block_start,ExFNIRS.settings.block_end);


answerTime = questdlg(sprintf('Choose times to export:\n\nCurrent sampling size is: %.1fs\n\nCurrent Viewing Window: %.1f to %.1fs\nCurrent Task Period %.1f:s to %.1fs\n\nNote: Incomplete bins will not be exported',ExFNIRS.settings.barchart_resample_size,ExFNIRS.settings.plot_start,ExFNIRS.settings.plot_end,ExFNIRS.settings.block_start,ExFNIRS.settings.block_end), ...
	strcat(answerFormat,': Export Time Selection'), ...
	'All Times','Viewing Window','Baseline to Task','Viewing Window');%'All Times','Viewing Window','Baseline to Task','Task Only','Cancel','Baseline to Task');

switch(answerTime)
    case 'All Times'
        t_start=min(curTimes(:,1));
        t_end=max(curTimes(:,3));
    case 'Viewing Window'
        t_start=ExFNIRS.settings.plot_start;
        t_end=ExFNIRS.settings.plot_end;
    case 'Baseline to Task'
        t_start=min(ExFNIRS.settings.baseline_start,ExFNIRS.settings.block_start);
        t_end=max(ExFNIRS.settings.baseline_end,ExFNIRS.settings.block_end);
    case 'Task Only'
        t_start=ExFNIRS.settings.block_start;
        t_end=ExFNIRS.settings.block_end;
end

startIdx=curTimes(:,1)>=t_start;
endIdx=curTimes(:,3)<=t_end;
curTimes=curTimes(startIdx&endIdx,:);

fprintf('Exporting Times:')
cTimesTable=cTimesTable(startIdx&endIdx,:);
display(cTimesTable);



% Handle response
switch answerFormat
    case 'Wide Format'
        exportWideTable(curTimes(:,1));
    case 'Long Format'
        exportLongTable(curTimes(:,1));
    case 'Cancel'

end

function myTable=remove9999(myTable)

for c=1:size(myTable,2)
    if(isnumeric(myTable{:,c}))
        myTable{myTable{:,c}==-9999,c}=nan;
    elseif(iscell(myTable{:,c})&&(ischar(myTable{:,c}{1})||isstring(myTable{:,c}{1})))
        myTable{strcmp('-9999',myTable{:,c}),c}={''};
    end
end

function myTable=nan_to_9999(myTable)

for c=1:size(myTable,2)
    if(isnumeric(myTable{:,c}))
        myTable{isnan(myTable{:,c}),c}=-9999;
    elseif(iscell(myTable{:,c})&&(ischar(myTable{:,c}{1})||isstring(myTable{:,c}{1})))
        myTable{strcmp('',myTable{:,c}),c}={'-9999'};
    end
end

function writeLogFile(logFileName,path)

global ExFNIRS

settings=ExFNIRS.settings;

fullPath=sprintf('%s/%s',path,logFileName);
fileID = fopen(fullPath,'w');
versInfo=exploreFNIRS.versInfo();
fprintf(fileID,'%s\n',versInfo);
fprintf(fileID,'Exported %s\n',datestr(datetime('now')));

fprintf(fileID,'Group By: %s\n',ExFNIRS.statusGroupByStr);
fprintf(fileID,'Cur Method: %s\n',ExFNIRS.curMethodName);
fprintf(fileID,'Averaging Method: %s\n',settings.within_sub_avg_mode_label);
fprintf(fileID,'GrandAvg Resample Size: %.2f\n',settings.grandavg_resample_size);
fprintf(fileID,'Resample Size: %.2f\n',settings.barchart_resample_size);
fprintf(fileID,'Baseline Start: %.2f\n',settings.baseline_start);
fprintf(fileID,'Baseline End: %.2f\n',settings.baseline_end);
fprintf(fileID,'Block Start: %.2f\n',settings.block_start);
fprintf(fileID,'Block End: %.2f\n',settings.block_end);
fprintf(fileID,'Feature: %s\n',settings.plot_bar_feature);

fprintf(fileID,'\n');

rawMethodDescrip=pf2.methods.raw.describeMethod();
fprintf(fileID,'%s\n',rawMethodDescrip);
oxyMethodDescrip=pf2.methods.oxy.describeMethod();
fprintf(fileID,'%s\n',oxyMethodDescrip);


fclose(fileID);

function exportWideTable(times)

global ExFNIRS

bioMList={'HbO','HbR','HbDiff','HbTotal','CBSI'};

if(isempty(ExFNIRS.selectedTable))
    return;
end

[file, pathname] = uiputfile({'*.csv';'*.mat';'*.*'},'Export Segment Table');
if(isempty(file)||~ischar(file)||(isnumeric(file)&&file==0))
    return
end

if(strcmp(lower(file(end-3:end)),'mat'))
    exportMAT=true;
else
    exportMAT=false;
end

logFileName=sprintf('%s_wide.log',file(1:end-4));

optodeNames=num2str(ExFNIRS.currentOpt);

exportTable=exploreFNIRS.export.mergeGbyTablesWide(ExFNIRS.gby,bioMList,[],times,true,true,optodeNames);

if(ExFNIRS.settings.export_replace_missing_9999)
    exportTable=nan_to_9999(exportTable);
else
    exportTable=remove9999(exportTable);
end

numGroups=length(ExFNIRS.gby);

if(exportMAT)
    grandAvgData=cell(1,numGroups);
    grandAvgBarData=cell(1,numGroups);
end

for g=1:numGroups
    curGby=ExFNIRS.gby(g);
    
    if(isempty(curGby))
        continue;
    end
    
    
    if(exportMAT)
        grandAvgData{g}=curGby.gbyGrand; 
        grandAvgBarData{g}=curBarGA;
    end
  
end


%if(ExFNIRS.settings.code_missing)
%    disp('Not yet enabled');
%end

if(~exportMAT)
    writetable(exportTable, sprintf('%s/%s',pathname,file),'QuoteStrings',true);
else
    save(sprintf('%s/%s',pathname,file),'exportTable','grandAvgData','grandAvgBarData');
end

writeLogFile(logFileName,pathname);

fprintf('Data exported to %s\n',sprintf('%s/%s',pathname,file));

function exportLongTable(times)

global ExFNIRS

bioMList={'HbO','HbR','HbDiff','HbTotal','CBSI'};

if(isempty(ExFNIRS.selectedTable))
    return;
end

[file, pathname] = uiputfile({'*.csv';'*.mat';'*.*'},'Export Segment Table');
if(isempty(file)||~ischar(file)||(isnumeric(file)&&file==0))
    return
end

if(strcmp(lower(file(end-3:end)),'mat'))
    exportMAT=true;
else
    exportMAT=false;
end

logFileName=sprintf('%s_long.log',file(1:end-4));

optodeNames=num2str(ExFNIRS.currentOpt);
exportTable=exploreFNIRS.export.mergeGbyTablesLong(ExFNIRS.gby,bioMList,[],times,true,true,optodeNames);


if(ExFNIRS.settings.export_replace_missing_9999)
    exportTable=nan_to_9999(exportTable);
else
    exportTable=remove9999(exportTable);
end


numGroups=length(ExFNIRS.gby);

if(exportMAT)
    grandAvgData=cell(1,numGroups);
    grandAvgBarData=cell(1,numGroups);
end

for g=1:numGroups
    curGby=ExFNIRS.gby(g);
    
    if(isempty(curGby))
        continue;
    end
    
    
    if(exportMAT)
        grandAvgData{g}=curGby.gbyGrand; 
        grandAvgBarData{g}=curBarGA;
    end
  
end


%if(ExFNIRS.settings.code_missing)
%    disp('Not yet enabled');
%end

if(~exportMAT)
    writetable(exportTable, sprintf('%s/%s',pathname,file),'QuoteStrings',true);
else
    save(sprintf('%s/%s',pathname,file),'exportTable','grandAvgData','grandAvgBarData');
end

writeLogFile(logFileName,pathname);

fprintf('Data exported to %s\n',sprintf('%s%s',pathname,file));


function initializeGUIvalues(handles)
% function sets an initializes values based on GUI settings
    global ExFNIRS;

    fprintf('Examining experimental data array\n');

numEx=length(ExFNIRS.data);
fsArray=nan(numEx);
for i=numEx:-1:1
    %if(rem(i,100)==0)
          fprintf('record %i of %i\n',i,numEx);
    %end
    if(isempty(ExFNIRS.data{i}))
        ExFNIRS.data(i)=[];
        continue;
    end
    if(isfield(ExFNIRS.data{i},'time'))
       fsArray(i)=median(diff(ExFNIRS.data{i}.time)); 
    end
    
    if( ExFNIRS.settings.timeShiftTo0)
        ExFNIRS.data{i}=pf2.data.setT0(ExFNIRS.data{i},min(ExFNIRS.data{i}.time));
    end
    
    if(isfield(ExFNIRS.data{i},'info'))
        ExFNIRS.data{i}.info.rowID=i;
    end
end

estimatedFS=nanmedian(fsArray(:));

% Resolve device and attach to all segments that lack one
try
    firstWithDevice = [];
    for i = 1:length(ExFNIRS.data)
        if isfield(ExFNIRS.data{i}, 'device') && isa(ExFNIRS.data{i}.device, 'pf2.Device')
            firstWithDevice = ExFNIRS.data{i}.device;
            break;
        end
    end
    if isempty(firstWithDevice) && ~isempty(ExFNIRS.data)
        firstWithDevice = pf2.Device.load(ExFNIRS.data{1});
    end
    if ~isempty(firstWithDevice)
        for i = 1:length(ExFNIRS.data)
            if ~isfield(ExFNIRS.data{i}, 'device') || ~isa(ExFNIRS.data{i}.device, 'pf2.Device')
                ExFNIRS.data{i}.device = firstWithDevice;
            end
        end
        fprintf('Device: %s (%d channels)\n', firstWithDevice.name, firstWithDevice.nChannels);
    end
catch ME
    warning('exploreFNIRS:DeviceResolve', 'Could not resolve device: %s', ME.message);
end

subIdAuto=1;

fprintf('Building experimental data array\n');
numEx=length(ExFNIRS.data);
for i=1:numEx
    fprintf('Preprocessing record %i of %i\n',i,numEx);

   if((~isfield(ExFNIRS.data{i},'raw')&&~isfield(ExFNIRS.data{i},'HbO'))||all(isnan(ExFNIRS.data{i}.time))||(length(ExFNIRS.data{i}.time)==1&&(isnan(ExFNIRS.data{i}.time)))||sum(sum(~isnan(ExFNIRS.data{i}.raw(:,2:end)),1),2)==0) %info only
       ExFNIRS.data{i}.time=nan;
       ExFNIRS.data{i}.info.missingFNIRS=1;
   else
       ExFNIRS.data{i}.info.missingFNIRS=0;
   end

   if(isfield(ExFNIRS.data{i},'Aux'))
        ExFNIRS.data{i}.info.emptyAux=isempty(ExFNIRS.data{i}.Aux)||isempty(fieldnames(ExFNIRS.data{i}.Aux));
   else
        ExFNIRS.data{i}.info.emptyAux=true;
   end
   
       
   if(~isfield(ExFNIRS.data{i}.info,'Group')||isempty(ExFNIRS.data{i}.info.Group))
       ExFNIRS.data{i}.info.Group='Missing';
   end
   
   if(~isfield(ExFNIRS.data{i}.info,'SubjectID')||isempty(ExFNIRS.data{i}.info.SubjectID))
       ExFNIRS.data{i}.info.SubjectID=sprintf('Missing%i',subIdAuto);
       subIdAuto=subIdAuto+1;
   end
   
   if(~isfield(ExFNIRS.data{i}.info,'Subgroup')||isempty(ExFNIRS.data{i}.info.Subgroup))
       ExFNIRS.data{i}.info.Subgroup='Missing';
   end
   
   if(~isfield(ExFNIRS.data{i}.info,'Session')||isempty(ExFNIRS.data{i}.info.Session))
       ExFNIRS.data{i}.info.Session='Missing';
   end
   
   if(~isfield(ExFNIRS.data{i}.info,'Trial')||isempty(ExFNIRS.data{i}.info.Trial))
       ExFNIRS.data{i}.info.Trial='Missing';
   end
   
   if(~isfield(ExFNIRS.data{i}.info,'Block')||isempty(ExFNIRS.data{i}.info.Block))
       ExFNIRS.data{i}.info.Block='Missing';
   end
   
   if(~isfield(ExFNIRS.data{i}.info,'Condition')||isempty(ExFNIRS.data{i}.info.Condition))
       ExFNIRS.data{i}.info.Condition='Missing';
   end
end


ExFNIRS.settings.plotby=[];
ExFNIRS.settings.plotby.SubjectID=get(handles.checkbox_subjectID_plotby,'Value');
ExFNIRS.settings.plotby.Group=get(handles.checkbox_group_plotby,'Value');
ExFNIRS.settings.plotby.Session=get(handles.checkbox_session_plotby,'Value');
ExFNIRS.settings.plotby.Trial=get(handles.checkbox_trial_plotby,'Value');
ExFNIRS.settings.plotby.Condition=get(handles.checkbox_condition_plotby,'Value');
ExFNIRS.settings.plotby.Block=get(handles.checkbox_block_plotby,'Value');
ExFNIRS.settings.plotby.InfoGroupBy=get(handles.checkbox_block_plotby,'Value');

fprintf('Building Info Table:\n');
ExFNIRS.dataTable=exploreFNIRS.dataset.buildSegmentInfoTable(ExFNIRS.data);


ExFNIRS.settings.updateOnChange=get(handles.checkbox_auto_update,'Value');


set(handles.popupmenu_info_field,'String',ExFNIRS.dataTable.Properties.VariableNames);
set(handles.popupmenu_info_field,'Value',length(ExFNIRS.dataTable.Properties.VariableNames));
strs=get(handles.popupmenu_info_field,'String');
val=get(handles.popupmenu_info_field,'Value');
selStr=strs{val};
ExFNIRS.settings.curInfoStr=selStr;

set(handles.popupmenu_groupby_info_field,'String',ExFNIRS.dataTable.Properties.VariableNames);
set(handles.popupmenu_groupby_info_field,'Value',1);
strs=get(handles.popupmenu_groupby_info_field,'String');
val=get(handles.popupmenu_groupby_info_field,'Value');
selStr=strs{val};
ExFNIRS.settings.curInfoGroupBy=selStr;

popupmenu_groupby_info_field_Callback([], [], handles); %update fieldbox



segInfoVars={'SubjectID','Group','Subgroup','Session','Trial','Block','Condition'};


for v =1:length(segInfoVars)
   if(~ismember(segInfoVars{v},ExFNIRS.dataTable.Properties.VariableNames))
        ExFNIRS.dataTable.(segInfoVars{v})=strings(size(ExFNIRS.dataTable,1),1);
        ExFNIRS.dataTable.(segInfoVars{v})(:,1)='Missing';
   elseif(isnumeric(ExFNIRS.dataTable.(segInfoVars{v})(1)))
       nIdx=isnan(ExFNIRS.dataTable.(segInfoVars{v}));
       if(any(nIdx))
          warning('Missing value to deal with'); 
       end
       %ExFNIRS.dataTable.(segInfoVars{v})(nIdx)=
   elseif(isstring(ExFNIRS.dataTable.(segInfoVars{v})(1)))
       nIdx=strcmp(ExFNIRS.dataTable.(segInfoVars{v}),'');
       ExFNIRS.dataTable.(segInfoVars{v})(nIdx)='Missing'; 
   end
end


%pf2('UseDeviceCFG','device_fNIR1200.cfg');
pf2('blLength',0); %use global mean for import

%ExFNIRS.settings=[];




ExFNIRS.settings.plot_grandaverage_feature='Mean';
ExFNIRS.settings.plot_grandaverage=get(handles.checkbox_plot_grandaverage,'Value');
ExFNIRS.settings.plot_individual=get(handles.checkbox_plot_all_data,'Value');
ExFNIRS.settings.plot_error=get(handles.checkbox_plot_error,'Value');
ExFNIRS.settings.plot_error_multiply=str2num(get(handles.edit_error_multiplier,'String'));
ExFNIRS.settings.plot_task_lines=get(handles.checkbox_mark_task,'Value');

set(handles.popupmenu_bar_error_feature,'String',{'SEM','SD','MaxMin','IQR','IQR-NoOutliers','Violin'});

idx=get(handles.popupmenu_errorbar_style,'Value');
strs=get(handles.popupmenu_errorbar_style,'String');
ExFNIRS.settings.plot_error_style=strs{idx};
idx=get(handles.popupmenu_errorbar_feature,'Value');
strs=get(handles.popupmenu_errorbar_feature,'String');
ExFNIRS.settings.plot_error_feature=strs{idx};

ExFNIRS.settings.plot_legend_mode=2; %1 none %2 last fig %3 all

if(isnan(ExFNIRS.settings.grandavg_resample_size))
   ExFNIRS.settings.grandavg_resample_size=estimatedFS*2;
end
set(handles.edit_grandavg_resample_size,'String',sprintf('%.3f',ExFNIRS.settings.grandavg_resample_size));
%ExFNIRS.settings.code_missing=get(handles.checkbox_code_nan,'Value');

ExFNIRS.settings.plot_bar_ga=get(handles.checkbox_plot_barchart_ga,'Value');
ExFNIRS.settings.plot_bar_all=get(handles.checkbox_plot_barchart_all_points,'Value');
ExFNIRS.settings.plot_bar_err_mult=str2double(get(handles.edit_bar_error_multiplier,'String'));
ExFNIRS.settings.plot_bar_err_feature='SEM';
ExFNIRS.settings.plot_bar_err=get(handles.checkbox_plot_barchart_error,'Value');
ExFNIRS.settings.plot_bar_feature='Mean';

ExFNIRS.settings.plot_scatter_err=get(handles.checkbox_plot_scatter_error,'Value');
ExFNIRS.settings.plot_scatter_err_mult=str2double(get(handles.edit_scatter_error_multiplier,'String'));
ExFNIRS.settings.plot_scatter_nonparametric=get(handles.checkbox_plot_scatter_nonparametric,'Value');
ExFNIRS.settings.plot_scatter_line=get(handles.checkbox_plot_scatter_line,'Value');
idx=get(handles.popupmenu_scatter_error_feature,'Value');
strs=get(handles.popupmenu_scatter_error_feature,'String');
ExFNIRS.settings.plot_scatter_err_feature=strs{idx};
ExFNIRS.settings.plot_scatter_extend=get(handles.checkbox_plot_scatter_extend,'Value');
idx=get(handles.popupmenu_scatter_error_style,'Value');
strs=get(handles.popupmenu_scatter_error_style,'String');
ExFNIRS.settings.plot_scatter_error_style=strs{idx};
ExFNIRS.settings.plot_scatter_flipxy=get(handles.checkbox_plot_scatter_flipxy,'Value');

ExFNIRS.settings.LME_enable=get(handles.checkbox_LME_enable,'Value');
ExFNIRS.settings.LME_all_interactions=get(handles.checkbox_LME_all_interactions,'Value');
ExFNIRS.settings.LME_info_covariate=get(handles.checkbox_LME_info_covariate,'Value');

ExFNIRS.settings.export_replace_missing_9999=get(handles.checkbox_export_9999,'Value');

ExFNIRS.settings.use_group=get(handles.checkbox_use_group,'Value');
if(ExFNIRS.settings.use_group)
    set(handles.listbox_group,'Enable','on');
    set(handles.listbox_subgroup,'Enable','off');
else
    set(handles.listbox_group,'Enable','off');
    set(handles.listbox_subgroup,'Enable','on');
end

ExFNIRS.settings.ylim_manual=get(handles.checkbox_ylim_manual,'Value');
ExFNIRS.settings.ylim_fixed=get(handles.checkbox_ylim_fixed,'Value');
ExFNIRS.settings.ylim_manual_min=str2num(get(handles.edit_ylim_min,'String'));
ExFNIRS.settings.ylim_manual_max=str2num(get(handles.edit_ylim_max,'String'));

ExFNIRS.settings.guiColor=ones(10,3);
ExFNIRS.settings.use_gui_color=get(handles.checkbox_gui_colors,'Value');

[exF_folder,name,ext] = fileparts(mfilename('fullpath'));
loadGUIcolors(sprintf('%s/prefs/%s',exF_folder,'exploreFNIRS_defaultColors.csv'),handles);

set(handles.popupmenu_colors,'String',exploreFNIRS.helper.listColormaps('qualitative'));
idx=get(handles.popupmenu_colors,'Value');
strs=get(handles.popupmenu_colors,'String');
ExFNIRS.settings.cmap=exploreFNIRS.helper.getColormap(strs{idx});

PopulateGUIfields(ExFNIRS.dataTable,handles);
strsRaw=get(handles.listbox_raw_methods,'String');
strsOxy=get(handles.listbox_oxy_methods,'String');

ExFNIRS.processedData=cell(length(strsOxy)*length(strsRaw),3);
ExFNIRS.numProcessed=0;

if isfield(ExFNIRS,'UpdateNeeded') && ExFNIRS.UpdateNeeded==4
    ExFNIRS.UpdateNeeded = 3;
elseif ~isfield(ExFNIRS,'UpdateNeeded')
    ExFNIRS.UpdateNeeded = 3;
end

% Create Experiment object for settings persistence and CLI round-trip
try
    ExFNIRS.experiment = exploreFNIRS.core.Experiment(ExFNIRS.data);
    syncSettingsToExperiment();
catch ME
    warning('exploreFNIRS:ExperimentInit', ...
        'Could not create Experiment object: %s', ME.message);
end

if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(3,handles);
end





function syncSettingsToExperiment()
% Sync current ExFNIRS.settings into the Experiment object
global ExFNIRS
if ~isfield(ExFNIRS, 'experiment'), return; end
ex = ExFNIRS.experiment;
s = ExFNIRS.settings;

ex.settings.baseline = [s.baseline_start, s.baseline_end];
ex.settings.useBaseline = s.use_baseline;
ex.settings.resampleRate = s.grandavg_resample_size;
ex.settings.barBinSize = s.barchart_resample_size;
ex.settings.taskStart = s.block_start;
modes = {'none', 'flat', 'hierarchy'};
if s.within_sub_avg_mode >= 1 && s.within_sub_avg_mode <= 3
    ex.settings.avgMode = modes{s.within_sub_avg_mode};
end
ex.settings.taskEnd = s.block_end;
if isfield(s, 'LME_timeModel') && ~isempty(s.LME_timeModel)
    ex.settings.timeModel = s.LME_timeModel;
end
if isfield(s, 'LME_polyOrder') && ~isempty(s.LME_polyOrder)
    ex.settings.polyOrder = s.LME_polyOrder;
end
ExFNIRS.experiment = ex;

function syncBlockSettingsUI(handles)
% Offer to update bar chart size and plot time when block times change
global ExFNIRS
s = ExFNIRS.settings;
taskDuration = s.block_end - s.block_start;

% Build list of proposed changes
changes = {};
if abs(s.barchart_resample_size - taskDuration) > 0.01
    changes{end+1} = sprintf('Update bar chart bin size to %.2fs (currently %.2fs)', ...
        taskDuration, s.barchart_resample_size);
end
if s.plot_end < s.block_end
    changes{end+1} = sprintf('Extend plot end to %.2fs (currently %.2fs)', ...
        s.block_end, s.plot_end);
end
if s.plot_start > s.block_start
    changes{end+1} = sprintf('Extend plot start to %.2fs (currently %.2fs)', ...
        s.block_start, s.plot_start);
end

if isempty(changes), return; end

msg = sprintf('Block (Task) window changed. Update these settings to match?\n\n%s', ...
    strjoin(changes, '\n'));
answer = questdlg(msg, 'Update Settings', 'Yes', 'No', 'Yes');
if ~strcmp(answer, 'Yes'), return; end

if abs(s.barchart_resample_size - taskDuration) > 0.01
    ExFNIRS.settings.barchart_resample_size = taskDuration;
    set(handles.edit_barchart_resample_size, 'String', sprintf('%.2f', taskDuration));
end
if s.plot_end < s.block_end
    ExFNIRS.settings.plot_end = s.block_end;
    set(handles.edit_plot_end, 'String', sprintf('%.2f', s.block_end));
end
if s.plot_start > s.block_start
    ExFNIRS.settings.plot_start = s.block_start;
    set(handles.edit_plot_start, 'String', sprintf('%.2f', s.block_start));
end

function labels = buildOptodeLabels(uOpt, data)
% Build display labels for optode listbox, marking short-sep channels
labels = arrayfun(@num2str, uOpt, 'UniformOutput', false);
try
    dev = [];
    for i = 1:length(data)
        if isfield(data{i},'device') && isa(data{i}.device,'pf2.Device')
            dev = data{i}.device;
            break;
        end
    end
    if ~isempty(dev) && dev.nShortSep > 0
        ssMask = dev.isShortSep();
        chList = dev.channelList();
        for k = 1:numel(uOpt)
            idx = find(chList == uOpt(k), 1);
            if ~isempty(idx) && idx <= numel(ssMask) && ssMask(idx)
                labels{k} = sprintf('%d (ss)', uOpt(k));
            end
        end
    end
catch
    % Fall back to plain numeric labels
end

% --- Executes on button press in checkbox_plot_all_data.
function checkbox_plot_all_data_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_plot_all_data (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_plot_all_data
global ExFNIRS
ExFNIRS.settings.plot_individual=get(handles.checkbox_plot_all_data,'Value');

% --- Executes on button press in checkbox_plot_grandaverage.
function checkbox_plot_grandaverage_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_plot_grandaverage (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_plot_grandaverage
global ExFNIRS
ExFNIRS.settings.plot_grandaverage=get(handles.checkbox_plot_grandaverage,'Value');

% --- Executes on selection change in popupmenu_grandaverage_feature.
function popupmenu_grandaverage_feature_Callback(hObject, eventdata, handles)
% hObject    handle to popupmenu_grandaverage_feature (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: contents = cellstr(get(hObject,'String')) returns popupmenu_grandaverage_feature contents as cell array
%        contents{get(hObject,'Value')} returns selected item from popupmenu_grandaverage_feature
global ExFNIRS
idx=get(handles.popupmenu_grandaverage_feature,'Value');
strs=get(handles.popupmenu_grandaverage_feature,'String');
ExFNIRS.settings.plot_grandaverage_feature=strs{idx};

% --- Executes during object creation, after setting all properties.
function popupmenu_grandaverage_feature_CreateFcn(hObject, eventdata, handles)
% hObject    handle to popupmenu_grandaverage_feature (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: popupmenu controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end


% --- Executes on button press in checkbox_plot_error.
function checkbox_plot_error_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_plot_error (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_plot_error
global ExFNIRS
ExFNIRS.settings.plot_error=get(handles.checkbox_plot_error,'Value');

% --- Executes on selection change in popupmenu_errorbar_feature.
function popupmenu_errorbar_feature_Callback(hObject, eventdata, handles)
% hObject    handle to popupmenu_errorbar_feature (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: contents = cellstr(get(hObject,'String')) returns popupmenu_errorbar_feature contents as cell array
%        contents{get(hObject,'Value')} returns selected item from popupmenu_errorbar_feature

global ExFNIRS

% Error bar for temporal plots
idx=get(handles.popupmenu_errorbar_feature,'Value');
strs=get(handles.popupmenu_errorbar_feature,'String');
ExFNIRS.settings.plot_error_feature=strs{idx};

% --- Executes during object creation, after setting all properties.
function popupmenu_errorbar_feature_CreateFcn(hObject, eventdata, handles)
% hObject    handle to popupmenu_errorbar_feature (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: popupmenu controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end



function edit_error_multiplier_Callback(hObject, eventdata, handles)
% hObject    handle to edit_error_multiplier (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: get(hObject,'String') returns contents of edit_error_multiplier as text
%        str2double(get(hObject,'String')) returns contents of edit_error_multiplier as a double
global ExFNIRS
ExFNIRS.settings.plot_error_multiply=str2num(get(handles.edit_error_multiplier,'String'));
set(handles.edit_error_multiplier,'String',sprintf('%.1f',ExFNIRS.settings.plot_error_multiply));

% --- Executes during object creation, after setting all properties.
function edit_error_multiplier_CreateFcn(hObject, eventdata, handles)
% hObject    handle to edit_error_multiplier (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: edit controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end


% --- Executes on button press in checkbox_plot_barchart_ga.
function checkbox_plot_barchart_ga_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_plot_barchart_ga (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_plot_barchart_ga
global ExFNIRS
ExFNIRS.settings.plot_bar_ga=get(handles.checkbox_plot_barchart_ga,'Value');

% --- Executes on selection change in popupmenu_feature.
function popupmenu_feature_Callback(hObject, eventdata, handles)
% hObject    handle to popupmenu_feature (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: contents = cellstr(get(hObject,'String')) returns popupmenu_feature contents as cell array
%        contents{get(hObject,'Value')} returns selected item from popupmenu_feature


% --- Executes during object creation, after setting all properties.
function popupmenu_feature_CreateFcn(hObject, eventdata, handles)
% hObject    handle to popupmenu_feature (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: popupmenu controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end


% --- Executes on button press in checkbox_code_nan.
function checkbox_code_nan_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_code_nan (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_code_nan
global ExFNIRS
ExFNIRS.settings.code_missing=get(handles.checkbox_code_nan,'Value');

% --- Executes on selection change in listbox_block.
function listbox_block_Callback(hObject, eventdata, handles)           
% hObject    handle to listbox_block (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: contents = cellstr(get(hObject,'String')) returns listbox_block contents as cell array
%        contents{get(hObject,'Value')} returns selected item from listbox_block
global ExFNIRS
if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(true,handles);
end


% --- Executes during object creation, after setting all properties.
function listbox_block_CreateFcn(hObject, eventdata, handles)
% hObject    handle to listbox_block (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: listbox controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end


% --- Executes on button press in pushbutton_block_select_all.
function pushbutton_block_select_all_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_block_select_all (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

strs=get(handles.listbox_block,'String');
if(iscell(strs)||ismatrix(strs))
    set(handles.listbox_block,'Value',[1:size(strs,1)]);
end

global ExFNIRS
if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(true,handles);
end

% --- Executes on button press in pushbutton_block_select_none.
function pushbutton_block_select_none_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_block_select_none (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

set(handles.listbox_block,'Value',[]);

% --- Executes on button press in checkbox_block_plotby.
function checkbox_block_plotby_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_block_plotby (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_block_plotby
global ExFNIRS
ExFNIRS.settings.plotby.Block=get(handles.checkbox_block_plotby,'Value');
if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(true,handles);
end

% --- Executes on button press in pushbutton_refresh_methods.
function pushbutton_refresh_methods_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_refresh_methods (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

curRawMethods=processFNIRS2_configureMethods('currentRawMethodsCallback',hObject,handles);
if(~isempty(curRawMethods))
   set(handles.listbox_raw_methods,'String',curRawMethods); 
end
curOxyMethods=processFNIRS2_configureMethods('currentOxyMethodsCallback',hObject,handles);
if(~isempty(curOxyMethods))
   set(handles.listbox_oxy_methods,'String',curOxyMethods); 
end

global ExFNIRS

if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(3,handles);
end


% --- Executes on button press in pushbutton_import_raw.
function pushbutton_import_raw_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_import_raw (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)
processFNIRS2('ImportOxyMethods','');

global ExFNIRS

if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(3,handles);
end



% --- Executes on button press in pushbutton_import_oxy.
function pushbutton_import_oxy_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_import_oxy (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)
processFNIRS2('ImportRawMethods','');

global ExFNIRS

if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(3,handles);
end


% --- Executes on button press in pushbutton_clear_processed.
function pushbutton_clear_processed_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_clear_processed (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

global ExFNIRS
strsRaw=get(handles.listbox_raw_methods,'String');
strsOxy=get(handles.listbox_oxy_methods,'String');

ExFNIRS.processedData=cell(length(strsOxy)*length(strsRaw),3);
ExFNIRS.numProcessed=0;

if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(3,handles);
end



function edit_grandavg_resample_size_Callback(hObject, eventdata, handles)
% hObject    handle to edit_grandavg_resample_size (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: get(hObject,'String') returns contents of edit_grandavg_resample_size as text
%        str2double(get(hObject,'String')) returns contents of edit_grandavg_resample_size as a double
global ExFNIRS
ExFNIRS.settings.grandavg_resample_size=str2num(get(handles.edit_grandavg_resample_size,'String'));
set(handles.edit_grandavg_resample_size,'String',sprintf('%.3f',ExFNIRS.settings.grandavg_resample_size));

strsRaw=get(handles.listbox_raw_methods,'String');
strsOxy=get(handles.listbox_oxy_methods,'String');

ExFNIRS.processedData=cell(length(strsOxy)*length(strsRaw),3);
ExFNIRS.numProcessed=0;

if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
   flagForUpdate(2,handles); 
end

exploreFNIRS.plotExTimeline();


% --- Executes during object creation, after setting all properties.
function edit_grandavg_resample_size_CreateFcn(hObject, eventdata, handles)
% hObject    handle to edit_grandavg_resample_size (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: edit controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end

function txt = myDataTipUpdateFcn(pointDataTip, event_obj)

 hAxes=get(pointDataTip,'Parent');
 pos = event_obj.Position;
 selectedObjectTag=event_obj.Target.Tag;
 
 if(~isempty(selectedObjectTag))
     txt={sprintf('%s\nt=%.2f, y=%.2f',selectedObjectTag,pos(1),pos(2))};
 else
     txt = {sprintf('t=%.2f, y=%.2f',pos(1),pos(2))};
 end
%disp(['You clicked X:',num2str(pos(1)),', Y:',num2str(pos(2))]);
    

 


% --- Executes on button press in pushbutton_plot_barchart.
function pushbutton_plot_barchart_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_plot_barchart (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

global ExFNIRS

if(ExFNIRS.UpdateNeeded)
    updateSelectedTable(handles);
end

multiPlot=false;

if(~isfield(ExFNIRS,'gby'))
    warning('No groups match selection criteria');
    return;
end

exploreFNIRS.plot.barchart(handles,ExFNIRS.settings,ExFNIRS.gby,ExFNIRS.groupByVars, true,false);




function coef2coefIdx(coefNames,anvNames)

mdlIdx








    

% --- Executes on selection change in popupmenu_bar_feature.
function popupmenu_bar_feature_Callback(hObject, eventdata, handles)
% hObject    handle to popupmenu_bar_feature (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: contents = cellstr(get(hObject,'String')) returns popupmenu_bar_feature contents as cell array
%        contents{get(hObject,'Value')} returns selected item from popupmenu_bar_feature

global ExFNIRS
idx=get(handles.popupmenu_bar_feature,'Value');
strs=get(handles.popupmenu_bar_feature,'String');
ExFNIRS.settings.plot_bar_feature=strs{idx};

% --- Executes during object creation, after setting all properties.
function popupmenu_bar_feature_CreateFcn(hObject, eventdata, handles)
% hObject    handle to popupmenu_bar_feature (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: popupmenu controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end


% --- Executes on button press in checkbox_plot_barchart_error.
function checkbox_plot_barchart_error_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_plot_barchart_error (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_plot_barchart_error

global ExFNIRS
ExFNIRS.settings.plot_bar_err=get(handles.checkbox_plot_barchart_error,'Value');

% --- Executes on selection change in popupmenu_bar_error_feature.
function popupmenu_bar_error_feature_Callback(hObject, eventdata, handles)
% hObject    handle to popupmenu_bar_error_feature (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: contents = cellstr(get(hObject,'String')) returns popupmenu_bar_error_feature contents as cell array
%        contents{get(hObject,'Value')} returns selected item from popupmenu_bar_error_feature
global ExFNIRS
idx=get(handles.popupmenu_bar_error_feature,'Value');
strs=get(handles.popupmenu_bar_error_feature,'String');
ExFNIRS.settings.plot_bar_err_feature=strs{idx};


% --- Executes during object creation, after setting all properties.
function popupmenu_bar_error_feature_CreateFcn(hObject, eventdata, handles)
% hObject    handle to popupmenu_bar_error_feature (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: popupmenu controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end



function edit_bar_error_multiplier_Callback(hObject, eventdata, handles)
% hObject    handle to edit_bar_error_multiplier (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: get(hObject,'String') returns contents of edit_bar_error_multiplier as text
%        str2double(get(hObject,'String')) returns contents of edit_bar_error_multiplier as a double
global ExFNIRS
ExFNIRS.settings.plot_bar_err_mult=str2double(get(handles.edit_bar_error_multiplier,'String'));
set(handles.edit_bar_error_multiplier,'String',sprintf('%.1f',ExFNIRS.settings.plot_bar_err_mult));

% --- Executes during object creation, after setting all properties.
function edit_bar_error_multiplier_CreateFcn(hObject, eventdata, handles)
% hObject    handle to edit_bar_error_multiplier (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: edit controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end


% --- Executes on button press in checkbox_plot_barchart_all_points.
function checkbox_plot_barchart_all_points_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_plot_barchart_all_points (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_plot_barchart_all_points

global ExFNIRS
ExFNIRS.settings.plot_bar_all=get(handles.checkbox_plot_barchart_all_points,'Value');

% --- Executes on button press in checkbox_mark_task.
function checkbox_mark_task_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_mark_task (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_mark_task
global ExFNIRS
ExFNIRS.settings.plot_task_lines=get(handles.checkbox_mark_task,'Value');

% --- Executes on button press in checkbox_shaded_err.
function checkbox_shaded_err_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_shaded_err (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_shaded_err

global ExFNIRS
ExFNIRS.settings.plot_error_shaded=get(handles.checkbox_shaded_err,'Value');


% --- Executes on button press in checkbox_auto_update.
function checkbox_auto_update_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_auto_update (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_auto_update
global ExFNIRS
ExFNIRS.settings.updateOnChange=get(handles.checkbox_auto_update,'Value');

if(ExFNIRS.settings.updateOnChange&&ExFNIRS.UpdateNeeded)
    updateSelectedTable(handles);
end


% --- Executes on selection change in listbox_subgroup.
function listbox_subgroup_Callback(hObject, eventdata, handles)
% hObject    handle to listbox_subgroup (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: contents = cellstr(get(hObject,'String')) returns listbox_subgroup contents as cell array
%        contents{get(hObject,'Value')} returns selected item from listbox_subgroup


global ExFNIRS

if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(true,handles);
end

% --- Executes during object creation, after setting all properties.
function listbox_subgroup_CreateFcn(hObject, eventdata, handles)
% hObject    handle to listbox_subgroup (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: listbox controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end


% --- Executes on button press in checkbox_use_group.
function checkbox_use_group_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_use_group (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_use_group
global ExFNIRS
ExFNIRS.settings.use_group=get(handles.checkbox_use_group,'Value');
set(handles.checkbox_use_subgroup,'Value',~ExFNIRS.settings.use_group);
if(ExFNIRS.settings.use_group)
    set(handles.listbox_group,'Enable','on');
    set(handles.listbox_subgroup,'Enable','off');
else
    set(handles.listbox_group,'Enable','off');
    set(handles.listbox_subgroup,'Enable','on');
end

if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(true,handles);
end
% --- Executes on button press in checkbox_use_subgroup.
function checkbox_use_subgroup_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_use_subgroup (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_use_subgroup

global ExFNIRS
ExFNIRS.settings.use_group=~get(handles.checkbox_use_subgroup,'Value');
set(handles.checkbox_use_group,'Value',ExFNIRS.settings.use_group);

if(ExFNIRS.settings.use_group)
    set(handles.listbox_group,'Enable','on');
    set(handles.listbox_subgroup,'Enable','off');
else
    set(handles.listbox_group,'Enable','off');
    set(handles.listbox_subgroup,'Enable','on');
end

if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(true,handles);
end


% --- Executes on selection change in popupmenu_colors.
function popupmenu_colors_Callback(hObject, eventdata, handles)
% hObject    handle to popupmenu_colors (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: contents = cellstr(get(hObject,'String')) returns popupmenu_colors contents as cell array
%        contents{get(hObject,'Value')} returns selected item from popupmenu_colors
global ExFNIRS
idx=get(handles.popupmenu_colors,'Value');
strs=get(handles.popupmenu_colors,'String');
ExFNIRS.settings.cmap=exploreFNIRS.helper.getColormap(strs{idx});

% --- Executes during object creation, after setting all properties.
function popupmenu_colors_CreateFcn(hObject, eventdata, handles)
% hObject    handle to popupmenu_colors (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: popupmenu controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end


% --- Executes on button press in checkbox_auto_color.
function checkbox_auto_color_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_auto_color (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_auto_color
global ExFNIRS
ExFNIRS.settings.use_gui_color=~get(handles.checkbox_auto_color,'Value');
set(handles.checkbox_gui_colors,'Value',ExFNIRS.settings.use_gui_color);

% --- Executes on button press in checkbox_gui_colors.
function checkbox_gui_colors_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_gui_colors (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_gui_colors
global ExFNIRS
ExFNIRS.settings.use_gui_color=get(handles.checkbox_gui_colors,'Value');
set(handles.checkbox_auto_color,'Value',~ExFNIRS.settings.use_gui_color);

% --- Executes on button press in pushbutton_gui_color_1.
function pushbutton_gui_color_1_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_gui_color_1 (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)
global ExFNIRS

ExFNIRS.settings.guiColor(1,:)=uisetcolor(ExFNIRS.settings.guiColor(1,:));
set(handles.pushbutton_gui_color_1,'ForegroundColor',ExFNIRS.settings.guiColor(1,:))


% --- Executes on button press in pushbutton_gui_color_3.
function pushbutton_gui_color_3_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_gui_color_3 (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)
global ExFNIRS

ExFNIRS.settings.guiColor(3,:)=uisetcolor(ExFNIRS.settings.guiColor(3,:));
set(handles.pushbutton_gui_color_3,'ForegroundColor',ExFNIRS.settings.guiColor(3,:))

% --- Executes on button press in pushbutton_gui_color_5.
function pushbutton_gui_color_5_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_gui_color_5 (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)
global ExFNIRS

ExFNIRS.settings.guiColor(5,:)=uisetcolor(ExFNIRS.settings.guiColor(5,:));
set(handles.pushbutton_gui_color_5,'ForegroundColor',ExFNIRS.settings.guiColor(5,:))

% --- Executes on button press in pushbutton_gui_color_7.
function pushbutton_gui_color_7_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_gui_color_7 (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)
global ExFNIRS

ExFNIRS.settings.guiColor(7,:)=uisetcolor(ExFNIRS.settings.guiColor(7,:));
set(handles.pushbutton_gui_color_7,'ForegroundColor',ExFNIRS.settings.guiColor(7,:))

% --- Executes on button press in pushbutton_gui_color_9.
function pushbutton_gui_color_9_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_gui_color_9 (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)
global ExFNIRS

ExFNIRS.settings.guiColor(9,:)=uisetcolor(ExFNIRS.settings.guiColor(9,:));
set(handles.pushbutton_gui_color_9,'ForegroundColor',ExFNIRS.settings.guiColor(9,:))

% --- Executes on button press in pushbutton_gui_color_2.
function pushbutton_gui_color_2_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_gui_color_2 (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)
global ExFNIRS

ExFNIRS.settings.guiColor(2,:)=uisetcolor(ExFNIRS.settings.guiColor(2,:));
set(handles.pushbutton_gui_color_2,'ForegroundColor',ExFNIRS.settings.guiColor(2,:))

% --- Executes on button press in pushbutton_gui_color_4.
function pushbutton_gui_color_4_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_gui_color_4 (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)
global ExFNIRS

ExFNIRS.settings.guiColor(4,:)=uisetcolor(ExFNIRS.settings.guiColor(4,:));
set(handles.pushbutton_gui_color_4,'ForegroundColor',ExFNIRS.settings.guiColor(4,:))

% --- Executes on button press in pushbutton_gui_color_6.
function pushbutton_gui_color_6_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_gui_color_6 (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)
global ExFNIRS

ExFNIRS.settings.guiColor(6,:)=uisetcolor(ExFNIRS.settings.guiColor(6,:));
set(handles.pushbutton_gui_color_6,'ForegroundColor',ExFNIRS.settings.guiColor(6,:))

% --- Executes on button press in pushbutton_gui_color_8.
function pushbutton_gui_color_8_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_gui_color_8 (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)
global ExFNIRS

ExFNIRS.settings.guiColor(8,:)=uisetcolor(ExFNIRS.settings.guiColor(8,:));
set(handles.pushbutton_gui_color_8,'ForegroundColor',ExFNIRS.settings.guiColor(8,:))

% --- Executes on button press in pushbutton_gui_color_10.
function pushbutton_gui_color_10_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_gui_color_10 (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)
global ExFNIRS

ExFNIRS.settings.guiColor(10,:)=uisetcolor(ExFNIRS.settings.guiColor(10,:));
set(handles.pushbutton_gui_color_10,'ForegroundColor',ExFNIRS.settings.guiColor(10,:))

% --- Executes on button press in pushbutton_gui_color_save.
function pushbutton_gui_color_save_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_gui_color_save (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

[file, pathname] = uiputfile({'*.csv';'*.*'},'Export colors list');
if(isempty(file)||~ischar(file)||(isnumeric(file)&&file==0))
    return
end
global ExFNIRS
csvwrite(sprintf('%s/%s',pathname,file),ExFNIRS.settings.guiColor);
% --- Executes on button press in pushbutton_gui_color_load.
function pushbutton_gui_color_load_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_gui_color_load (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

[file, pathname] = uigetfile({'*.csv';'*.*'},'Import colors list');
if(isempty(file)||~ischar(file)||(isnumeric(file)&&file==0))
    return
end

loadGUIcolors(sprintf('%s/%s',pathname,file),handles);

function loadGUIcolors(csvPath,handles)
global ExFNIRS
cRead=csvread(csvPath);

if(size(cRead,1)<=10&&size(cRead,2)==3)
    cRead(cRead>1)=1;
    cRead(cRead<0)=0;
    ExFNIRS.settings.guiColor(1:size(cRead,1),:)=cRead;
    
    updateButtonListColors(handles);
    set(handles.listbox_color_order,'String',cellstr(num2str([1:10]')));
    set(handles.listbox_color_order,'Value',1);

else
    
    error('Expected a (1-10)x3 RGB color matrix');
end


% --- Executes on selection change in popupmenu_legend_mode.
function popupmenu_legend_mode_Callback(hObject, eventdata, handles)
% hObject    handle to popupmenu_legend_mode (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: contents = cellstr(get(hObject,'String')) returns popupmenu_legend_mode contents as cell array
%        contents{get(hObject,'Value')} returns selected item from popupmenu_legend_mode
global ExFNIRS
ExFNIRS.settings.plot_legend_mode=get(handles.popupmenu_legend_mode,'Value');

% --- Executes during object creation, after setting all properties.
function popupmenu_legend_mode_CreateFcn(hObject, eventdata, handles)
% hObject    handle to popupmenu_legend_mode (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: popupmenu controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end


% --- Executes on button press in pushbutton_process_selection.
function pushbutton_process_selection_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_process_selection (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

updateSelectedTable(handles);


% --- Executes on selection change in listbox_hierarchy.
function listbox_hierarchy_Callback(hObject, eventdata, handles)
% hObject    handle to listbox_hierarchy (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: contents = cellstr(get(hObject,'String')) returns listbox_hierarchy contents as cell array
%        contents{get(hObject,'Value')} returns selected item from listbox_hierarchy
global ExFNIRS

if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(true,handles);
end

% --- Executes during object creation, after setting all properties.
function listbox_hierarchy_CreateFcn(hObject, eventdata, handles)
% hObject    handle to listbox_hierarchy (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: listbox controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end


% --- Executes on button press in pushbutton_move_hierarchy_up.
function pushbutton_move_hierarchy_up_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_move_hierarchy_up (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

hierarchyStr=get(handles.listbox_hierarchy,'String');
hierarchyVal=get(handles.listbox_hierarchy,'Value');

numHstr=length(hierarchyStr);
if(hierarchyVal==1)
    return;
else
    newInd=[1:hierarchyVal-2,hierarchyVal,hierarchyVal-1,(hierarchyVal+1):numHstr];
    newInd(newInd>numHstr)=[];
    set(handles.listbox_hierarchy,'String',hierarchyStr(newInd));
    set(handles.listbox_hierarchy,'Value',hierarchyVal-1);
end

hierarchyStr=get(handles.listbox_hierarchy,'String');

global ExFNIRS
ExFNIRS.dataHierarchy(2:numHstr+1)=hierarchyStr;


if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(true,handles);
end

% --- Executes on button press in pushbutton_move_hierarchy_down.
function pushbutton_move_hierarchy_down_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_move_hierarchy_down (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)
hierarchyStr=get(handles.listbox_hierarchy,'String');
hierarchyVal=get(handles.listbox_hierarchy,'Value');

numHstr=length(hierarchyStr);
if(hierarchyVal==numHstr)
    return;
else
    newInd=[1:hierarchyVal-1,hierarchyVal+1,hierarchyVal,(hierarchyVal+2):numHstr];
    newInd(newInd>numHstr)=[];
    set(handles.listbox_hierarchy,'String',hierarchyStr(newInd));
    set(handles.listbox_hierarchy,'Value',hierarchyVal+1);
end

hierarchyStr=get(handles.listbox_hierarchy,'String');
global ExFNIRS
ExFNIRS.dataHierarchy(2:numHstr+1)=hierarchyStr;

if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(true,handles);
end


% --- Executes on selection change in popupmenu_within_sub_avg.
function popupmenu_within_sub_avg_Callback(hObject, eventdata, handles)
% hObject    handle to popupmenu_within_sub_avg (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: contents = cellstr(get(hObject,'String')) returns popupmenu_within_sub_avg contents as cell array
%        contents{get(hObject,'Value')} returns selected item from popupmenu_within_sub_avg
global ExFNIRS
ExFNIRS.settings.within_sub_avg_mode=get(handles.popupmenu_within_sub_avg,'Value');

if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(true,handles);
end

% --- Executes during object creation, after setting all properties.
function popupmenu_within_sub_avg_CreateFcn(hObject, eventdata, handles)
% hObject    handle to popupmenu_within_sub_avg (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: popupmenu controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end


% --- Executes on button press in pushbutton_infoData_barchart.
function pushbutton_infoData_barchart_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_infoData_barchart (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)


global ExFNIRS

if(ExFNIRS.UpdateNeeded)
   updateSelectedTable(handles); 
end

if(~isfield(ExFNIRS,'gby'))
    warning('No groups match selection criteria');
    return;
end

exploreFNIRS.plot.barchart_infogroup(handles,ExFNIRS.settings,ExFNIRS.gby,ExFNIRS.groupByVars);


function displayLME(lme_mdl)
%disp(lme_mdl.Forumla);
fprintf(2,'\nUse These DFs\n');
[~,~,stats]=fixedEffects(lme_mdl,'DFMethod','satterthwaite');
disp(stats);
%disp(lme_mdl.RandomEffects);
% [~,~,stats]=randomEffects(lme_mdl,'DFMethod','satterthwaite');
% disp(stats);
disp(anova(lme_mdl,'DFMethod','satterthwaite'));



% --- Executes on selection change in popupmenu_info_field.
function popupmenu_info_field_Callback(hObject, eventdata, handles)
% hObject    handle to popupmenu_info_field (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: contents = cellstr(get(hObject,'String')) returns popupmenu_info_field contents as cell array
%        contents{get(hObject,'Value')} returns selected item from popupmenu_info_field
global ExFNIRS

strs=get(handles.popupmenu_info_field,'String');
val=get(handles.popupmenu_info_field,'Value');

selStr=strs{val};

ExFNIRS.settings.curInfoStr=selStr;

% --- Executes during object creation, after setting all properties.
function popupmenu_info_field_CreateFcn(hObject, eventdata, handles)
% hObject    handle to popupmenu_info_field (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: popupmenu controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end


% --- Executes on selection change in popupmenu_info_group.
function popupmenu_info_group_Callback(hObject, eventdata, handles)
% hObject    handle to popupmenu_info_group (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: contents = cellstr(get(hObject,'String')) returns popupmenu_info_group contents as cell array
%        contents{get(hObject,'Value')} returns selected item from popupmenu_info_group

global ExFNIRS

strs=get(handles.popupmenu_info_group,'String');
val=get(handles.popupmenu_info_group,'Value');

selStr=strs{val};

ExFNIRS.settings.curInfoGroup=selStr;

updateInfoGroupByVars(handles);

% --- Executes during object creation, after setting all properties.
function popupmenu_info_group_CreateFcn(hObject, eventdata, handles)
% hObject    handle to popupmenu_info_group (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: popupmenu controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end


% --- Executes on button press in checkbox_ylim_fixed.
function checkbox_ylim_fixed_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_ylim_fixed (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_ylim_fixed
global ExFNIRS

ExFNIRS.settings.ylim_fixed=get(handles.checkbox_ylim_fixed,'Value');

if(ExFNIRS.settings.ylim_fixed)
   set(handles.checkbox_ylim_manual,'Value',0); 
   ExFNIRS.settings.ylim_manual=false;
end

% --- Executes on button press in checkbox_ylim_manual.
function checkbox_ylim_manual_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_ylim_manual (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_ylim_manual

global ExFNIRS

ExFNIRS.settings.ylim_manual=get(handles.checkbox_ylim_manual,'Value');

if(ExFNIRS.settings.ylim_manual)
   set(handles.checkbox_ylim_fixed,'Value',0); 
   ExFNIRS.settings.ylim_fixed=false;
end


function edit_ylim_min_Callback(hObject, eventdata, handles)
% hObject    handle to edit_ylim_min (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: get(hObject,'String') returns contents of edit_ylim_min as text
%        str2double(get(hObject,'String')) returns contents of edit_ylim_min as a double
global ExFNIRS

ExFNIRS.settings.ylim_manual_min=str2double(get(handles.edit_ylim_min,'String'));
set(handles.edit_ylim_min,'String',sprintf('%.2f',ExFNIRS.settings.ylim_manual_min));

% --- Executes during object creation, after setting all properties.
function edit_ylim_min_CreateFcn(hObject, eventdata, handles)
% hObject    handle to edit_ylim_min (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: edit controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end



function edit_ylim_max_Callback(hObject, eventdata, handles)
% hObject    handle to edit_ylim_max (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: get(hObject,'String') returns contents of edit_ylim_max as text
%        str2double(get(hObject,'String')) returns contents of edit_ylim_max as a double
global ExFNIRS

ExFNIRS.settings.ylim_manual_max=str2double(get(handles.edit_ylim_max,'String'));
set(handles.edit_ylim_max,'String',sprintf('%.2f',ExFNIRS.settings.ylim_manual_max));

% --- Executes during object creation, after setting all properties.
function edit_ylim_max_CreateFcn(hObject, eventdata, handles)
% hObject    handle to edit_ylim_max (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: edit controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end


% --- Executes on button press in pushbutton_plot_scatter.
function pushbutton_plot_scatter_Callback(hObject, eventdata, handles,plotTopo)
% hObject    handle to pushbutton_plot_scatter (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)



global ExFNIRS


if(ExFNIRS.UpdateNeeded)
   updateSelectedTable(handles); 
end

if(nargin<4)
   plotTopo=false; 
end

if(~isfield(ExFNIRS,'gby'))
    warning('No groups match selection criteria');
    return;
end


exploreFNIRS.plot.scatter(handles,ExFNIRS.settings,ExFNIRS.gby,ExFNIRS.groupByVars,plotTopo);


% --- Executes on selection change in popupmenu_errorbar_style.
function popupmenu_errorbar_style_Callback(hObject, eventdata, handles)
% hObject    handle to popupmenu_errorbar_style (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: contents = cellstr(get(hObject,'String')) returns popupmenu_errorbar_style contents as cell array
%        contents{get(hObject,'Value')} returns selected item from popupmenu_errorbar_style

global ExFNIRS

idx=get(handles.popupmenu_errorbar_style,'Value');
strs=get(handles.popupmenu_errorbar_style,'String');
ExFNIRS.settings.plot_error_style=strs{idx};

% --- Executes during object creation, after setting all properties.
function popupmenu_errorbar_style_CreateFcn(hObject, eventdata, handles)
% hObject    handle to popupmenu_errorbar_style (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: popupmenu controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end


% --- Executes on button press in checkbox_plot_scatter_error.
function checkbox_plot_scatter_error_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_plot_scatter_error (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_plot_scatter_error

global ExFNIRS
ExFNIRS.settings.plot_scatter_err=get(handles.checkbox_plot_scatter_error,'Value');

% --- Executes on selection change in popupmenu_scatter_error_feature.
function popupmenu_scatter_error_feature_Callback(hObject, eventdata, handles)
% hObject    handle to popupmenu_scatter_error_feature (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: contents = cellstr(get(hObject,'String')) returns popupmenu_scatter_error_feature contents as cell array
%        contents{get(hObject,'Value')} returns selected item from popupmenu_scatter_error_feature

global ExFNIRS
idx=get(handles.popupmenu_scatter_error_feature,'Value');
strs=get(handles.popupmenu_scatter_error_feature,'String');
ExFNIRS.settings.plot_scatter_err_feature=strs{idx};


% --- Executes during object creation, after setting all properties.
function popupmenu_scatter_error_feature_CreateFcn(hObject, eventdata, handles)
% hObject    handle to popupmenu_scatter_error_feature (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: popupmenu controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end



function edit_scatter_error_multiplier_Callback(hObject, eventdata, handles)
% hObject    handle to edit_scatter_error_multiplier (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: get(hObject,'String') returns contents of edit_scatter_error_multiplier as text
%        str2double(get(hObject,'String')) returns contents of edit_scatter_error_multiplier as a double

global ExFNIRS
ExFNIRS.settings.plot_scatter_err_mult=str2double(get(handles.edit_scatter_error_multiplier,'String'));
set(handles.edit_scatter_error_multiplier,'String',sprintf('%.1f',ExFNIRS.settings.plot_scatter_err_mult));

% --- Executes during object creation, after setting all properties.
function edit_scatter_error_multiplier_CreateFcn(hObject, eventdata, handles)
% hObject    handle to edit_scatter_error_multiplier (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: edit controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end


% --- Executes on button press in checkbox_plot_scatter_nonparametric.
function checkbox_plot_scatter_nonparametric_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_plot_scatter_nonparametric (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_plot_scatter_nonparametric

global ExFNIRS
ExFNIRS.settings.plot_scatter_nonparametric=get(handles.checkbox_plot_scatter_nonparametric,'Value');


% --- Executes on button press in checkbox_plot_scatter_line.
function checkbox_plot_scatter_line_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_plot_scatter_line (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_plot_scatter_line

global ExFNIRS
ExFNIRS.settings.plot_scatter_line=get(handles.checkbox_plot_scatter_line,'Value');


% --- Executes on selection change in popupmenu_scatter_error_style.
function popupmenu_scatter_error_style_Callback(hObject, eventdata, handles)
% hObject    handle to popupmenu_scatter_error_style (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: contents = cellstr(get(hObject,'String')) returns popupmenu_scatter_error_style contents as cell array
%        contents{get(hObject,'Value')} returns selected item from popupmenu_scatter_error_style

global ExFNIRS

idx=get(handles.popupmenu_scatter_error_style,'Value');
strs=get(handles.popupmenu_scatter_error_style,'String');
ExFNIRS.settings.plot_scatter_error_style=strs{idx};


% --- Executes during object creation, after setting all properties.
function popupmenu_scatter_error_style_CreateFcn(hObject, eventdata, handles)
% hObject    handle to popupmenu_scatter_error_style (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: popupmenu controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end


% --- Executes on button press in checkbox_plot_scatter_extend.
function checkbox_plot_scatter_extend_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_plot_scatter_extend (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_plot_scatter_extend
global ExFNIRS
ExFNIRS.settings.plot_scatter_extend=get(handles.checkbox_plot_scatter_extend,'Value');


% --- Executes on selection change in popupmenu_groupby_info_field.
function popupmenu_groupby_info_field_Callback(hObject, eventdata, handles)
% hObject    handle to popupmenu_groupby_info_field (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: contents = cellstr(get(hObject,'String')) returns popupmenu_groupby_info_field contents as cell array
%        contents{get(hObject,'Value')} returns selected item from popupmenu_groupby_info_field

global ExFNIRS

strs=get(handles.popupmenu_groupby_info_field,'String');
val=get(handles.popupmenu_groupby_info_field,'Value');

selStr=strs{val};

ExFNIRS.settings.use_info=true;


ExFNIRS.settings.curInfoGroupBy=selStr;
infoVars=ExFNIRS.dataTable.Properties.VariableNames;

set(handles.popupmenu_groupby_info_field,'String',infoVars);
[a,b]=ismember(ExFNIRS.settings.curInfoGroupBy,infoVars);

if(a==1)
    set(handles.popupmenu_groupby_info_field,'Value',b);
else
    set(handles.popupmenu_groupby_info_field,'Value',1);
end

idx=get(handles.popupmenu_groupby_info_field,'Value');
ExFNIRS.settings.curInfoGroupBy=infoVars{idx};

ExFNIRS.settings.curInfoGroupByNumeric=false;

if(~isempty(ExFNIRS.settings.curInfoGroupBy))
    [uVars,~,ExFNIRS.settings.curInfoGroupByIdx]=unique(ExFNIRS.dataTable(:,ExFNIRS.settings.curInfoGroupBy));
    
    if(isnumeric(uVars{1,1}))
       uVars=table2array(ExFNIRS.dataTable(:,ExFNIRS.settings.curInfoGroupBy));
       uVars(isnan(uVars))=-9999;
       %uVars=unique(uVars);
       %uVars(uVars==-9999)=nan;
       uVars=num2str(uVars,'%.2f');
       ExFNIRS.settings.curInfoGroupByNumeric=true;
       [uVars,~,ExFNIRS.settings.curInfoGroupByIdx]=unique(uVars,'rows');
    elseif(isstring(uVars{1,1}))
       uVars=table2cell(uVars); 
    end
    if(~iscell(uVars))
        uVars=cellstr(uVars);
    end
    
    for i=1:length(uVars)
       if(isempty(uVars{i,1})||(isstring(uVars{i})&&ismissing(uVars{i}))||(ischar(uVars{i})&&ismissing(uVars(i))))
          uVars{i,1}='Missing'; 
       end
    end
    
    nanIndex=strcmp('-9999.00',uVars);
    
    
    uVars(nanIndex)={'NaN'};
    set(handles.listbox_info_groupby,'String',uVars);
    set(handles.listbox_info_groupby,'Value',1:length(uVars));
    
    
    
    segInfoVars={'Group','Subgroup','Session','Trial','Block','Condition',ExFNIRS.settings.curInfoGroupBy};
    randFxStr{1}='1|SubjectID';
    for i=2:2:length(segInfoVars)*2
       randFxStr{i}=sprintf('%s|SubjectID',segInfoVars{(i)/2}); 
       randFxStr{i+1}=sprintf('-1+%s|SubjectID',segInfoVars{(i)/2}); 
    end

    set(handles.popupmenu_lmer_randomeffects,'String',randFxStr);
    ExFNIRS.settings.LME_randomFxStrs=randFxStr;

else
    set(handles.listbox_info_groupby,'String','');
end

if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(true,handles);
end

% --- Executes during object creation, after setting all properties.
function popupmenu_groupby_info_field_CreateFcn(hObject, eventdata, handles)
% hObject    handle to popupmenu_groupby_info_field (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: popupmenu controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end


% --- Executes on selection change in listbox_info_groupby.
function listbox_info_groupby_Callback(hObject, eventdata, handles)
% hObject    handle to listbox_info_groupby (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: contents = cellstr(get(hObject,'String')) returns listbox_info_groupby contents as cell array
%        contents{get(hObject,'Value')} returns selected item from listbox_info_groupby

global ExFNIRS


if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(true,handles);
end


% --- Executes during object creation, after setting all properties.
function listbox_info_groupby_CreateFcn(hObject, eventdata, handles)
% hObject    handle to listbox_info_groupby (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: listbox controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end


% --- Executes on button press in pushbutton_info_groupby_select_all.
function pushbutton_info_groupby_select_all_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_info_groupby_select_all (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

strs=get(handles.listbox_info_groupby,'String');
if(iscell(strs)||ismatrix(strs))
    set(handles.listbox_info_groupby,'Value',[1:size(strs,1)]);
end

global ExFNIRS

if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(true,handles);
end


% --- Executes on button press in pushbutton_info_groupby_select_none.
function pushbutton_info_groupby_select_none_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_info_groupby_select_none (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

global ExFNIRS

strs=get(handles.listbox_info_groupby,'String');
if(iscell(strs)||ismatrix(strs))
    set(handles.listbox_info_groupby,'Value',[]);
end

if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(true,handles);
end




% --- Executes on button press in checkbox_info_groupby_plotby.
function checkbox_info_groupby_plotby_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_info_groupby_plotby (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_info_groupby_plotby
global ExFNIRS
ExFNIRS.settings.plotby.InfoGroupBy=get(handles.checkbox_info_groupby_plotby,'Value');
if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(true,handles);
end


% --- Executes on button press in checkbox_plot_scatter_flipxy.
function checkbox_plot_scatter_flipxy_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_plot_scatter_flipxy (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_plot_scatter_flipxy
global ExFNIRS
ExFNIRS.settings.plot_scatter_flipxy=get(handles.checkbox_plot_scatter_flipxy,'Value');


% --- Executes on selection change in listbox_color_order.
function listbox_color_order_Callback(hObject, eventdata, handles)
% hObject    handle to listbox_color_order (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: contents = cellstr(get(hObject,'String')) returns listbox_color_order contents as cell array
%        contents{get(hObject,'Value')} returns selected item from listbox_color_order


% --- Executes during object creation, after setting all properties.
function listbox_color_order_CreateFcn(hObject, eventdata, handles)
% hObject    handle to listbox_color_order (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: listbox controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end


% --- Executes on button press in pushbutton_gui_color_move_up.
function pushbutton_gui_color_move_up_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_gui_color_move_up (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

global ExFNIRS

colorStr=get(handles.listbox_color_order,'String');
colorVal=get(handles.listbox_color_order,'Value');

if(isempty(colorVal))
    set(handles.listbox_color_order,'Value',1);
    colorVal=1;
end

numClrStr=length(colorStr);
if(colorVal==1)
    return;
else
    newInd=[1:colorVal-2,colorVal,colorVal-1,(colorVal+1):numClrStr];
    newInd(newInd>numClrStr)=[];
    ExFNIRS.settings.guiColor=ExFNIRS.settings.guiColor(newInd,:);
    set(handles.listbox_color_order,'String',colorStr(newInd));
    set(handles.listbox_color_order,'Value',colorVal-1);
end

updateButtonListColors(handles);


function updateButtonListColors(handles)

global ExFNIRS

set(handles.pushbutton_gui_color_1,'ForegroundColor',ExFNIRS.settings.guiColor(1,:));
set(handles.pushbutton_gui_color_2,'ForegroundColor',ExFNIRS.settings.guiColor(2,:));
set(handles.pushbutton_gui_color_3,'ForegroundColor',ExFNIRS.settings.guiColor(3,:));
set(handles.pushbutton_gui_color_4,'ForegroundColor',ExFNIRS.settings.guiColor(4,:));
set(handles.pushbutton_gui_color_5,'ForegroundColor',ExFNIRS.settings.guiColor(5,:));
set(handles.pushbutton_gui_color_6,'ForegroundColor',ExFNIRS.settings.guiColor(6,:));
set(handles.pushbutton_gui_color_7,'ForegroundColor',ExFNIRS.settings.guiColor(7,:));
set(handles.pushbutton_gui_color_8,'ForegroundColor',ExFNIRS.settings.guiColor(8,:));
set(handles.pushbutton_gui_color_9,'ForegroundColor',ExFNIRS.settings.guiColor(9,:));
set(handles.pushbutton_gui_color_10,'ForegroundColor',ExFNIRS.settings.guiColor(10,:));

colorStr=get(handles.listbox_color_order,'String');

% --- Executes on button press in pushbutton_gui_color_move_down.
function pushbutton_gui_color_move_down_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_gui_color_move_down (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

global ExFNIRS

colorStr=get(handles.listbox_color_order,'String');
colorVal=get(handles.listbox_color_order,'Value');

if(isempty(colorVal))
    set(handles.listbox_color_order,'Value',1);
    colorVal=1;
end

numClrStr=length(colorStr);
if(colorVal==length(colorStr))
    return;
else
    newInd=[(1:colorVal-1),(colorVal+1),colorVal,(colorVal+2):numClrStr];
    newInd(newInd>numClrStr)=[];
    ExFNIRS.settings.guiColor=ExFNIRS.settings.guiColor(newInd,:);
    set(handles.listbox_color_order,'String',colorStr(newInd));
    set(handles.listbox_color_order,'Value',colorVal+1);
end

updateButtonListColors(handles);


% --- Executes on button press in checkbox_LME_enable.
function checkbox_LME_enable_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_LME_enable (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_LME_enable

global ExFNIRS
ExFNIRS.settings.LME_enable=get(handles.checkbox_LME_enable,'Value');



% --- Executes on button press in checkbox_LME_all_interactions.
function checkbox_LME_all_interactions_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_LME_all_interactions (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_LME_all_interactions

global ExFNIRS
ExFNIRS.settings.LME_all_interactions=get(handles.checkbox_LME_all_interactions,'Value');


% --- Executes on button press in checkbox_LME_info_covariate.
function checkbox_LME_info_covariate_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_LME_info_covariate (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_LME_info_covariate

global ExFNIRS
ExFNIRS.settings.LME_info_covariate=get(handles.checkbox_LME_info_covariate,'Value');


% --- Executes on button press in pushbutton_lme_plot_topo.
function pushbutton_lme_plot_topo_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_lme_plot_topo (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)
global ExFNIRS
switch(ExFNIRS.settings.ChannelMode)
    case 'fNIR'
        strs=get(handles.listbox_optode,'String');
        if(iscell(strs)||ismatrix(strs))
            set(handles.listbox_optode,'Value',[1:size(strs,1)]);
        end
    case 'ROI'
        
    case 'Aux'
        
end

if(ExFNIRS.UpdateNeeded)
   updateSelectedTable(handles); 

   %return;
end

exploreFNIRS.plot.barchart(handles,ExFNIRS.settings,ExFNIRS.gby,ExFNIRS.groupByVars, false,true);


% --- Executes on button press in checkbox_export_9999.
function checkbox_export_9999_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_export_9999 (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_export_9999

global ExFNIRS
ExFNIRS.settings.export_replace_missing_9999=get(handles.checkbox_export_9999,'Value');


% --- Executes on selection change in popupmenu_ChannelMode.
function popupmenu_ChannelMode_Callback(hObject, eventdata, handles)
% hObject    handle to popupmenu_ChannelMode (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: contents = cellstr(get(hObject,'String')) returns popupmenu_ChannelMode contents as cell array
%        contents{get(hObject,'Value')} returns selected item from popupmenu_ChannelMode
global ExFNIRS

idx=get(handles.popupmenu_ChannelMode,'Value');
setExChannelMode(ExFNIRS.settings.ChannelModes{idx,2},handles);

function setExChannelMode(modeStr,handles,initROI,initAux,initOPT)
% sets the channel mode and changes GUI to match

if(nargin<5)
    initOPT=false;
end

if(nargin<4)
    initAux=false;
end


if(nargin<3)
    initROI=false;
end

global ExFNIRS
ExFNIRS.settings.ChannelMode=modeStr;


switch (ExFNIRS.settings.ChannelMode)
    case 'fNIR'
        if(initOPT||~isfield(ExFNIRS,'currentOpt')||isempty(ExFNIRS.currentOpt))
            uOpt=[];
            for i=1:length(ExFNIRS.data)
                d=ExFNIRS.data{i};
                if isfield(d,'channels')
                    uOpt=[uOpt;d.channels(:)];
                elseif isfield(d,'device') && ~isempty(d.device)
                    uOpt=[uOpt;d.device.channelNumbers()'];
                elseif isfield(d,'HbO')
                    nCh=size(d.HbO,2)-1; % subtract marker column
                    if nCh>0; uOpt=[uOpt;(1:nCh)']; end
                elseif isfield(d,'raw') && isfield(d,'fchMask')
                    nCh=length(d.fchMask);
                    if nCh>0; uOpt=[uOpt;(1:nCh)']; end
                end
            end
            uOpt=uOpt(uOpt>0); % exclude marker column (-1) and time (0)
            uOpt=sort(unique(uOpt));

            ExFNIRS.currentOpt=uOpt;
            ExFNIRS.currentOptLabels=buildOptodeLabels(uOpt,ExFNIRS.data);
        else
            uOpt=ExFNIRS.currentOpt;
            if ~isfield(ExFNIRS,'currentOptLabels')||isempty(ExFNIRS.currentOptLabels)
                ExFNIRS.currentOptLabels=buildOptodeLabels(uOpt,ExFNIRS.data);
            end
        end

        set(handles.text_optode_label,'String','Optode');
        set(handles.text_biomarker_label,'String','BioMarker');
        set(handles.listbox_biomarker,'Enable','on');
        set(handles.pushbutton_biomarker_select_all,'Enable','on');
        set(handles.pushbutton_biomarker_select_none,'Enable','on');
        set(handles.listbox_optode,'Enable','on');
        set(handles.pushbutton_optodes_select_all,'Enable','on');
        set(handles.pushbutton_optodes_select_none,'Enable','on');


        set(handles.listbox_optode,'String',ExFNIRS.currentOptLabels);
        set(handles.listbox_optode,'Value',1);
        set(handles.listbox_optode,'UserData',[]);

        set(handles.listbox_biomarker,'String',{'HbO','HbR','HbDiff','HbTotal','CBSI'});
        
        set(handles.pushbutton_lme_plot_topo,'Enable','on');
    case 'ROI'

        if(initROI||~isfield(ExFNIRS,'currentROI')) % standaradize all ROIs on first load
            
            [uROI,uROInames,ExFNIRS.data]=exploreFNIRS.dataset.standardizeROIs(ExFNIRS.data);

            ExFNIRS.currentROInames=uROInames;
            ExFNIRS.currentROI=uROI;
            
            %end
             fprintf(2,'************Standardization Complete!\n********\n');

            
        else
            uROI=ExFNIRS.currentROI;
            uROInames=ExFNIRS.currentROInames;
        end
        
        if(isempty(uROI))
            warning('No ROIs present in data');
            warndlg('No ROIs defined in loaded data. Define ROIs first.', 'Channel Mode');
            set(handles.popupmenu_ChannelMode,'Value',1);
            setExChannelMode('fNIR',handles,false,false);
        else
            %uROI=unique(uROI{:},'rows');           

            set(handles.text_optode_label,'String','ROI');
            set(handles.text_biomarker_label,'String','BioMarker');
            set(handles.listbox_biomarker,'Enable','on');
            set(handles.pushbutton_biomarker_select_all,'Enable','on');
            set(handles.pushbutton_biomarker_select_none,'Enable','on');
            
            set(handles.listbox_optode,'Enable','on');
            set(handles.pushbutton_optodes_select_all,'Enable','on');
            set(handles.pushbutton_optodes_select_none,'Enable','on');

            set(handles.listbox_optode,'String',uROInames);
            set(handles.listbox_optode,'Value',1);
            set(handles.listbox_optode,'UserData',[]);

            set(handles.listbox_biomarker,'String',{'HbO','HbR','HbDiff','HbTotal','CBSI'});
            set(handles.pushbutton_lme_plot_topo,'Enable','on');
        end
    case 'Aux'

        if(initAux||~isfield(ExFNIRS,'currentAux'))
        
            auxNames={}; %ex: hrv_data
            uAux={};
            auxVarNames={}; %ex: bpm
            cacheAuxVarNames={};
    
            fprintf('Scanning Aux fields...\n');
            uAuxNames = {};
            uAuxVarNames = {};

            if(pf2_base.isnestedfield(ExFNIRS,'curPreprocessedFNIR.fNIR')&&~isempty(ExFNIRS.curPreprocessedFNIR.fNIR))
    
                for i=1:length(ExFNIRS.curPreprocessedFNIR.fNIR)
                    if(pf2_base.isnestedfield(ExFNIRS.curPreprocessedFNIR.fNIR{i},'Aux'))
                        curAuxNames=fieldnames(ExFNIRS.curPreprocessedFNIR.fNIR{i}.Aux);
                        if(any(~ismember(curAuxNames,auxNames)))
                            
                            for auxf=1:length(curAuxNames)
                                curField=ExFNIRS.curPreprocessedFNIR.fNIR{i}.Aux.(curAuxNames{auxf});
        
                                if(istable(curField))
                                    auxNames=[auxNames,curAuxNames{auxf}];
                                    auxNames=unique(auxNames);

                                    auxFidx=find(strcmp(curAuxNames{auxf},auxNames));
        
                                    curTableVars=curField.Properties.VariableNames;
                                    cacheAuxVarNames{auxFidx}=curTableVars;
    
                                    for auxnum=1:size(curField,2)
                                        newVarNamesIdx=~ismember(curTableVars,auxVarNames);
                                        if(any(newVarNamesIdx))
                                            auxVarNames=[auxVarNames,curTableVars(newVarNamesIdx)];
                                        end
                                        
                                    end
                                end
                            end
                        end
                    end
                end
    
                [uAuxNames,b,c]=unique(auxNames);
                uAuxNames=auxNames(b);
    
                [uAuxVarNames,b,c]=unique(auxVarNames);
                uAuxVarNames=auxVarNames(b);
    
                auxVarTable=array2table(nan([length(uAuxNames),length(uAuxVarNames)]),'VariableNames',uAuxVarNames,'RowNames',uAuxNames);
    
                for sIdx=1:length(uAuxNames)
                    %for vIdx=1:length(auxVarNames)
                    curVarNames=cacheAuxVarNames{sIdx};
                    [varExistsIdx,varIdxMap]=ismember(uAuxVarNames,curVarNames);
                    if(any(varExistsIdx))
                        varIdx=find(varExistsIdx);
                        for vI=1:length(varIdx)
                            curIdx=varIdxMap(varIdx(vI));
                            curVarName=curVarNames{curIdx};
                            
                            auxVarTable{sIdx,curVarName}=curIdx;
                        end
                    end

                    timeIdx=auxVarTable{sIdx,'time'};
                    auxVarTable{sIdx,auxVarTable{sIdx,:}>timeIdx}=auxVarTable{sIdx,auxVarTable{sIdx,:}>timeIdx}-1;
                    
                    %end
                end

                auxVarTable(:,'time')=[];
    
    
                ExFNIRS.currentAux.auxVarTable=auxVarTable;
                uAuxNames=auxVarTable.Properties.RowNames;
                uAuxVarNames=auxVarTable.Properties.VariableNames;
            else
                warning('fNIRS data must be processed at least once first in order to flatten Aux data');
                warndlg('Process data first to access auxiliary channels.', 'Channel Mode');
            end
            
        else
            
            auxVarTable=ExFNIRS.currentAux.auxVarTable;
            uAuxNames=auxVarTable.Properties.RowNames;
            uAuxVarNames=auxVarTable.Properties.VariableNames;
        end

        auxVarNamesNoTime=uAuxVarNames(~strcmp(uAuxVarNames,'time'));



        if(isempty(uAuxVarNames)||isempty(auxVarNamesNoTime))
            warning('No Auxillary channels or data present in data');
            warndlg('No auxiliary data present in loaded data.', 'Channel Mode');
            set(handles.popupmenu_ChannelMode,'Value',1);
            setExChannelMode('fNIR',handles,false,false);
        else

 
            set(handles.text_optode_label,'String','Aux');
            set(handles.text_biomarker_label,'String','Aux Signal');
            set(handles.listbox_optode,'Enable','on');
            set(handles.pushbutton_optodes_select_all,'Enable','on');
            set(handles.pushbutton_optodes_select_none,'Enable','on');
            set(handles.listbox_biomarker,'Enable','on');
            set(handles.pushbutton_biomarker_select_all,'Enable','on');
            set(handles.pushbutton_biomarker_select_none,'Enable','on');
            set(handles.listbox_optode,'String',uAuxVarNames);
            set(handles.listbox_optode,'UserData',auxVarTable);          
            set(handles.listbox_optode,'Value',1);
            set(handles.listbox_biomarker,'Value',1);
            set(handles.listbox_biomarker,'String',uAuxNames);
            set(handles.pushbutton_lme_plot_topo,'Enable','off');
        end
end


% --- Executes during object creation, after setting all properties.
function popupmenu_ChannelMode_CreateFcn(hObject, eventdata, handles)
% hObject    handle to popupmenu_ChannelMode (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: popupmenu controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end


% --- Executes on button press in checkbox_LME_use_intercept.
function checkbox_LME_use_intercept_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_LME_use_intercept (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_LME_use_intercept

global ExFNIRS

ExFNIRS.settings.LME_use_intercept=get(handles.checkbox_LME_use_intercept,'Value');

% --- Executes on button press in checkbox_process_raw.
function checkbox_process_raw_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_process_raw (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_process_raw

global ExFNIRS

ExFNIRS.settings.processRaw=get(handles.checkbox_process_raw,'Value');

if(ExFNIRS.settings.processRaw)
    set(handles.listbox_raw_methods,'Enable','on');
else
    set(handles.listbox_raw_methods,'Enable','off');
    set(handles.listbox_raw_methods,'Value',1);
end

if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(3,handles);
end


% --- Executes on button press in checkbox_discreteTime.
function checkbox_discreteTime_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_discreteTime (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_discreteTime
global ExFNIRS
ExFNIRS.settings.LME_use_discreteTime=get(handles.checkbox_discreteTime,'Value');
% Map legacy checkbox to new TimeModel setting
if ExFNIRS.settings.LME_use_discreteTime
    ExFNIRS.settings.LME_timeModel = 'discrete';
else
    ExFNIRS.settings.LME_timeModel = 'polynomial';
end


% --- Executes on selection change in popupmenu_lmer_randomeffects.
function popupmenu_lmer_randomeffects_Callback(hObject, eventdata, handles)
% hObject    handle to popupmenu_lmer_randomeffects (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: contents = cellstr(get(hObject,'String')) returns popupmenu_lmer_randomeffects contents as cell array
%        contents{get(hObject,'Value')} returns selected item from popupmenu_lmer_randomeffects
global ExFNIRS

ExFNIRS.settings.LME_randomFxStr=ExFNIRS.settings.LME_randomFxStrs{get(handles.popupmenu_lmer_randomeffects,'Value')};


% --- Executes during object creation, after setting all properties.
function popupmenu_lmer_randomeffects_CreateFcn(hObject, eventdata, handles)
% hObject    handle to popupmenu_lmer_randomeffects (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: popupmenu controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end

% --- If Enable == 'on', executes on mouse press in 5 pixel border.
% --- Otherwise, executes on mouse press in 5 pixel border or over popupmenu_lmer_randomeffects.
function popupmenu_lmer_randomeffects_ButtonDownFcn(hObject, eventdata, handles)
% hObject    handle to popupmenu_lmer_randomeffects (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)



% --- Executes on button press in checkbox_lme_usecustom.
function checkbox_lme_usecustom_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_lme_usecustom (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_lme_usecustom

global ExFNIRS

ExFNIRS.settings.LME_use_customStr=get(handles.checkbox_lme_usecustom,'Value');

if(ExFNIRS.settings.LME_use_customStr&&isempty(ExFNIRS.settings.LME_customStr))
    pushbutton_custom_lme_Callback([], [], handles);
else
    
end


% --- Executes on button press in pushbutton_custom_lme.
function pushbutton_custom_lme_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_custom_lme (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

global ExFNIRS

prompt = {'Please enter custom LME string'};
dlgtitle = 'Define custom LME model terms';
dims = [1 100];
answer = inputdlg(prompt,dlgtitle,dims,{ExFNIRS.settings.LME_customStr});

if(~isempty(answer))
    ExFNIRS.settings.LME_customStr=answer{1};
    set(handles.checkbox_lme_usecustom,'Value',1);
    ExFNIRS.settings.LME_use_customStr=true;
    set(handles.pushbutton_custom_lme,'TooltipString',answer{1});

else
    
end




% --- Executes on selection change in popupmenu_topoSig.
function popupmenu_topoSig_Callback(hObject, eventdata, handles)
% hObject    handle to popupmenu_topoSig (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hints: contents = cellstr(get(hObject,'String')) returns popupmenu_topoSig contents as cell array
%        contents{get(hObject,'Value')} returns selected item from popupmenu_lmer_randomeffects
global ExFNIRS

switch(get(handles.popupmenu_topoSig,'Value'))
    case 1 % p=0.1
       ExFNIRS.settings.topoSigThrehold={'p',0.1};
    case 2 % p=0.05
       ExFNIRS.settings.topoSigThrehold={'p',0.05};
    case 3
       ExFNIRS.settings.topoSigThrehold={'p',0.01};
   case 4
       ExFNIRS.settings.topoSigThrehold={'q',0.1};
   case 5
       ExFNIRS.settings.topoSigThrehold={'q',0.05};
   case 6
       ExFNIRS.settings.topoSigThrehold={'q-twostep',0.1};
   case 7
       ExFNIRS.settings.topoSigThrehold={'q-twostep',0.05};
end


% --- Executes during object creation, after setting all properties.
function popupmenu_topoSig_CreateFcn(hObject, eventdata, handles)
% hObject    handle to popupmenu_topoSig (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    empty - handles not created until after all CreateFcns called

% Hint: popupmenu controls usually have a white background on Windows.
%       See ISPC and COMPUTER.
if ispc && isequal(get(hObject,'BackgroundColor'), get(0,'defaultUicontrolBackgroundColor'))
    set(hObject,'BackgroundColor','white');
end


% --- Executes on button press in checkbox_yaxis.
function checkbox_yaxis_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_yaxis (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_yaxis

global ExFNIRS

ExFNIRS.settings.plot_temporal_y0=get(handles.checkbox_yaxis,'Value');




% --- Executes on button press in pushbutton_exLoad.
function pushbutton_exLoad_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_exLoad (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

exploreFNIRS.loadEx();

% --- Executes on button press in pushbutton_exSave.
function pushbutton_exSave_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_exSave (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

exploreFNIRS.saveEx();


% --- Executes on button press in pushbutton_plot_scatter_topo.
function pushbutton_plot_scatter_topo_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_plot_scatter_topo (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

global ExFNIRS

switch(ExFNIRS.settings.ChannelMode)
    case 'fNIR'
        strs=get(handles.listbox_optode,'String');
        if(iscell(strs)||ismatrix(strs))
            set(handles.listbox_optode,'Value',[1:size(strs,1)]);
        end
    case 'ROI'
        
    case 'Aux'
        
end

pushbutton_plot_scatter_Callback(hObject, eventdata, handles,true);


% --- Executes on button press in checkbox_usebaseline.
function checkbox_usebaseline_Callback(hObject, eventdata, handles)
% hObject    handle to checkbox_usebaseline (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)

% Hint: get(hObject,'Value') returns toggle state of checkbox_usebaseline


global ExFNIRS

ExFNIRS.settings.use_baseline=get(handles.checkbox_usebaseline,'Value');
if(ExFNIRS.settings.updateOnChange)
    updateSelectedTable(handles);
else
    flagForUpdate(2,handles);
end

if(ExFNIRS.settings.use_baseline)
   set(handles.edit_baseline_start,'Enable','on');
   set(handles.edit_baseline_end,'Enable','on');
else
    set(handles.edit_baseline_start,'Enable','off');
    set(handles.edit_baseline_end,'Enable','off');
end



% --- Executes on button press in pushbutton_infoData_scatter.
function pushbutton_infoData_scatter_Callback(hObject, eventdata, handles)
% hObject    handle to pushbutton_infoData_scatter (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)
% hObject    handle to pushbutton_plot_scatter (see GCBO)
% eventdata  reserved - to be defined in a future version of MATLAB
% handles    structure with handles and user data (see GUIDATA)



global ExFNIRS


if(ExFNIRS.UpdateNeeded)
   updateSelectedTable(handles); 
end

if(~isfield(ExFNIRS,'gby'))
    warning('No groups match selection criteria');
    return;
end

curInfoGroup=ExFNIRS.settings.curInfoGroup; % Plot by

curInfoVarY=ExFNIRS.settings.curInfoGroupBy; % y Var
curInfoVarX=ExFNIRS.settings.curInfoStr; % X var

gbyVars=ExFNIRS.groupByVars;
if(~isempty(curInfoGroup)&&~strcmp(curInfoGroup,'(Time)'))
    [ismem,idx]=ismember(curInfoGroup,gbyVars);
    if(ismem)
        gbyVars(idx)=[];
        useCurInfoGroup=true;
    else
        useCurInfoGroup=false;
    end
else
    useCurInfoGroup=false;
end

numGroups=length(ExFNIRS.gby);

if(numGroups==0)
    return;
end


if(ExFNIRS.settings.ylim_fixed)
    ExFNIRS.settings.ylim_fixed_min=inf;
    xlim_fixed_min=inf;
    ExFNIRS.settings.ylim_fixed_max=-inf;
    xlim_fixed_max=-inf;
end


% end

gbyStrs=cell(numGroups,1);
gbyShortStrs=cell(numGroups,1);
curInfoGby=cell(0);

for g=1:numGroups
    gbyStrs{g}='';
    gbyShortStrs{g}='';
   if(~isempty(ExFNIRS.gby(g).gbyTables))
       for i=1:length(gbyVars)
           gbyStrs{g}=sprintf('%s%s:%s,',gbyStrs{g},gbyVars{i},num2strOrNot(ExFNIRS.gby(g).gbyTables.(gbyVars{i})(1)));
           gbyShortStrs{g}=sprintf('%s%s:%s,',gbyShortStrs{g},gbyVars{i}(1),num2strOrNot(ExFNIRS.gby(g).gbyTables.(gbyVars{i})(1)));
       end 
       if(useCurInfoGroup)
           curInfoGby{g}=num2strOrNot(ExFNIRS.gby(g).gbyTables.(curInfoGroup)(1));
       end
   end 
   if(~isempty(gbyStrs{g}))
        gbyStrs{g}(end)='';
        gbyShortStrs{g}(end)='';
   end
end

numUgroups=length(unique(cellstr(gbyStrs)));

if(numUgroups==1)
    num2Plot=1;
    if(ExFNIRS.settings.use_gui_color)
        cIndex=ExFNIRS.settings.guiColor(1:numUgroups,:);
    else
        cIndex=ExFNIRS.settings.cmap(numUgroups);%linspecer(num2Plot,'qualitative');
    end
else
    num2Plot=numGroups;
    if(ExFNIRS.settings.use_gui_color)
        cIndex=ExFNIRS.settings.guiColor(1:numUgroups,:);
    else
        cIndex=ExFNIRS.settings.cmap(numUgroups);%linspecer(num2Plot,'qualitative');
    end
end


[uCurInfoG,firstCurIdx,uCurIdx]=unique(cellstr(curInfoGby));
numCurInfoG=max(uCurIdx);
uCurGIdxCount=nan(size(uCurIdx));
for i =1:numCurInfoG
    uCurGIdxCount(uCurIdx==i)=1:sum(uCurIdx==i);
end

if(~useCurInfoGroup||isnan(numCurInfoG))
   useCurInfoGroup=false;
   numCurInfoG=1; 
   uCurInfoG='';
end


errorFeature=ExFNIRS.settings.plot_bar_err_feature;
plotFeature=ExFNIRS.settings.plot_bar_feature;

if(strcmp(plotFeature,'Count')&&ExFNIRS.settings.plot_bar_ga)
    plotFeature='N';
    plotCount=true;
else
    plotCount=false;
end


subplotHandles=cell(numCurInfoG,1);


if(numCurInfoG>1)
    xType='groupby';
    yType='';
    figType='';
    numSubX=numCurInfoG;
    numSubY=1;
else
    xType='';
    yType='';
    figType='';
    numSubX=numCurInfoG;
    numSubY=1;
end

sH{1,1}.h=figure(1200);
clf(sH{1,1}.h);
dcm_obj = datacursormode(sH{1,1}.h);
set(dcm_obj,'UpdateFcn',@myDataTipUpdateFcn);
for s=1:(numSubX*numSubY)
    xInd=rem(s,numSubX);
    if(xInd==0)
        xInd=numSubX;
    end
    h=subplot(numSubY,numSubX,s);
    sH{1,1}.subH{floor((s-1)/numSubX)+1,xInd}=h;
    
    legend(h, 'off');
end

curSx=1;
curSy=1;
curFigIdx=[1,1];


curInfoStr=ExFNIRS.settings.curInfoStr;

if(ExFNIRS.settings.within_sub_avg_mode==3)
    dataH=ExFNIRS.dataHierarchy;
elseif(ExFNIRS.settings.within_sub_avg_mode==2)
    dataH='SubjectID';
else
    dataH=[];
end




legendGFXhandles{1}=[];
legendGFXstrs{1}=cell(0);
    
num2Plot=numUgroups;
   
    
pointStrs=cell(num2Plot,1);
gAStrs=cell(num2Plot,1);
gAerrStrs=cell(num2Plot,1);
    
curChart=1;

curUstrX="";
curUstrX(1)=[];
curUstrY="";
curUstrY(1)=[];

plotXstr=false;
plotYstr=false;

        
for g=1:numGroups
    curTable=ExFNIRS.gby(g).gbyTables;
    curDataX=curTable(:,curInfoVarX);
    curDataX=table2array(curDataX);
    curDataY=curTable(:,curInfoVarY);
    curDataY=table2array(curDataY);
    
    if(isstring(curDataX)||ischar(curDataX))
       %warning('Strings return count');
       curDataX=string(curDataX);
       [uDataX,~,curDataIdx]=unique(curDataX);
       if(~isempty(uDataX))
           curUstrX(end+1:end+length(uDataX))=uDataX;
           [curUstrX,~,curUidxX]=unique(curUstrX);
           curDataX=nan(size(curDataIdx));
           for udx=1:length(uDataX)
               cdx=find(ismember(curUstrX,uDataX(udx)));
               curDataX(curDataIdx==udx)=cdx;
           end
           %plotFeature='String';
           % return;
           plotXstr=true;
       end
    end
    curDataX(curDataX==-9999)=nan;
    
    if(isstring(curDataY)||ischar(curDataY))
       %warning('Strings return count');
       curDataY=string(curDataY);
       [uDataY,~,curDataIdxY]=unique(curDataY);
       if(~isempty(uDataY))
           curUstrY(end+1:end+length(uDataY))=uDataY;
           [curUstrY,~,curUidxY]=unique(curUstrY);
           curDataY=nan(size(curDataIdxY));
           for udx=1:length(uDataY)
               cdx=find(ismember(curUstrY,uDataY(udx)));
               curDataY(curDataIdxY==udx)=cdx;
           end
           %plotFeature='String';
           plotYstr=true;
           % return;
       end
    end
    curDataY(curDataY==-9999)=nan;
            
    if(useCurInfoGroup)
        curGroupInfoIdx=uCurIdx(g);
        curGroupIdxOffset=(curGroupInfoIdx-1)*1;
        curUgroupIdx=uCurGIdxCount(g);
    else
        curGroupInfoIdx=1;
        curGroupIdxOffset=0;
        curUgroupIdx=g;
    end
            
    if(useCurInfoGroup)
        if(strcmp(xType,'groupby'))
            curSx=curGroupInfoIdx;
        elseif(strcmp(yType,'groupby'))
            curSy=curGroupInfoIdx;
        end
    end
            
    if(strcmp(xType,'ugroup'))
        curSx=curUgroupIdx;
    elseif(strcmp(yType,'ugroup'))
        curSy=curUgroupIdx;
    end
            
            
            
            
    if(plotXstr)
        [curHAvgX,outH]=pf2_base.hierarchicalAverage(curDataX,curTable(:,dataH),@mode);
    elseif(strcmp(plotFeature,'Mean'))
        [curHAvgX,outH]=pf2_base.hierarchicalAverage(curDataX,curTable(:,dataH),@nanmean);
    elseif(strcmp(plotFeature,'Median'))
        [curHAvgX,outH]=pf2_base.hierarchicalAverage(curDataX,curTable(:,dataH),@nanmedian);
    elseif(strcmp(plotFeature,'Count')||strcmp(plotFeature,'N'))
        [curHAvgX,outH]=pf2_base.hierarchicalAverage(curDataX,curTable(:,dataH),@nnz);
    else
        error('Unknown parameter');
        %curHAvg=nanmedian(hierarchicalAverage(curData,curTable(:,dataH),@nanmedian));
    end
    
    if(plotYstr)
        [curHAvgY,outH]=pf2_base.hierarchicalAverage(curDataY,curTable(:,dataH),@mode);
    elseif(strcmp(plotFeature,'Mean'))
        [curHAvgY,outH]=pf2_base.hierarchicalAverage(curDataY,curTable(:,dataH),@nanmean);
    elseif(strcmp(plotFeature,'Median'))
        [curHAvgY,outH]=pf2_base.hierarchicalAverage(curDataY,curTable(:,dataH),@nanmedian);
    elseif(strcmp(plotFeature,'Count')||strcmp(plotFeature,'N'))
        [curHAvgY,outH]=pf2_base.hierarchicalAverage(curDataY,curTable(:,dataH),@nnz);
    else
        error('Unknown parameter');
        %curHAvg=nanmedian(hierarchicalAverage(curData,curTable(:,dataH),@nanmedian));
    end
            
    curSy=1;
                
    curPlotHandle=sH{curFigIdx(1),curFigIdx(2)}.subH{curSy,curSx};
    lastSubPlot=(curSy==numSubY&&curSx==numSubX);
    hold(curPlotHandle,'on')
                
                
    curFeatureY=curHAvgY;          
                
                
                
            
                
    if(length(curFeatureY)~=length(curHAvgX))
        if(length(curFeatureY)>length(curHAvgX))
            curFeatureY=curFeatureY(ismember(curGrand.info.Observation,outH));
        else
            temp=nan(size(curHAvgX));
            temp(ismember(outH,curGrand.info.Observation))=curFeatureY;
            curFeatureY=temp;
        end
    end
                
     
     sColor=cIndex(curUgroupIdx,:);
               
                
               
                
    if(ExFNIRS.settings.plot_scatter_nonparametric)



        validIdx=sum([isnan(curHAvgX),isnan(curFeatureY)],2)==0;
        validIdx=validIdx&(~isempty(curHAvgX)&&~isempty(curFeatureY));
        xVals=curHAvgX(validIdx);
        yVals=curFeatureY(validIdx);

        [~,p] = sort(xVals,'descend');
        r = 1:length(xVals);
        r(p) = r;
        xVals=r';

        [~,p] = sort(yVals,'descend');
        r = 1:length(yVals);
        r(p) = r;
        yVals=r';

        validIdx=sum([isnan(xVals),isnan(yVals)],2)==0;
        validIdx=validIdx&(~isempty(curHAvgX)&&~isempty(curFeatureY));

        xVals=xVals(validIdx);
        yVals=yVals(validIdx);
        N=length(xVals);
    else
        validIdx=sum([isnan(curHAvgX),isnan(curFeatureY)],2)==0;
        validIdx=validIdx&(~isempty(curHAvgX)&&~isempty(curFeatureY));
        xVals=curHAvgX(validIdx);
        yVals=curFeatureY(validIdx);
        N=length(xVals);
    end
    
     if(plotXstr)
       uData=[xVals,yVals];
       microvar=(nanmax(yVals)-nanmin(yVals))/100;
        [uRows,~,uRowIdx]=unique(uData,'rows');
        bincounts = histc(uRowIdx,1:max(uRowIdx));
        for xv=1:length(bincounts)
            if(bincounts(xv)>1)
               stepsize=0.8/(bincounts(xv)-1);
               offset=(-0.4:stepsize:0.4);
               if(bincounts(xv)<10)
                   offset=offset/(10-bincounts(xv));
               else
                    offset=(abs(offset).^1.5).*sign(offset);
               end
               xVals(uRowIdx==xv)=[uRows(xv,1)+offset];
               yVals(uRowIdx==xv)=[uRows(xv,2)-microvar+g/numGroups*(2*microvar)];
            end
           
        end
    end
    
    if(plotYstr)
        uData=[xVals,yVals];
        microvar=(nanmax(xVals)-nanmin(xVals))/100;
        [uRows,~,uRowIdx]=unique(uData,'rows');
        bincounts = histc(uRowIdx,1:max(uRowIdx));
        for yv=1:length(bincounts)
            if(bincounts(yv)>1)
               stepsize=0.8/(bincounts(yv)-1);
               offset=(-0.4:stepsize:0.4);
               if(bincounts(yv)<10)
                   offset=offset/(10-bincounts(yv));
               else
                   offset=(abs(offset).^1.5).*sign(offset);
               end
               yVals(uRowIdx==yv)=[uRows(yv,2)+offset];
               xVals(uRowIdx==yv)=[uRows(yv,1)-microvar+g/numGroups*(2*microvar)];
            end
           
        end
    end

    if(ExFNIRS.settings.plot_scatter_flipxy)
        temp=xVals;
        xVals=yVals;
        yVals=temp;
        
       
    end

   

        sHdots=scatter(curPlotHandle,xVals,yVals,25,sColor,'filled');

           pointStrs{curUgroupIdx}= gbyStrs{g};
           curPointStr=pointStrs{curUgroupIdx};
           %if(ExFNIRS.settings.plot_legend_mode==3||(ExFNIRS.settings.plot_legend_mode==2&&lastSubPlot))
               sH{curFigIdx(1),curFigIdx(2)}.legendHandles{curSy,curSx}.h{curUgroupIdx}=sHdots;
           %end

        tagStr=sprintf('%s',curPointStr); 
        set(sHdots,'tag',tagStr);


        curFeatureString=sprintf('%s',curInfoVarY);


        if(ExFNIRS.settings.plot_scatter_nonparametric)
            curFeatureString=sprintf('Rank %s',curFeatureString);
        end

        switch(xType)
            case 'groupby'
                title_with_space(curPlotHandle,curInfoGby{g});
        end
        
        


        if(ExFNIRS.settings.plot_scatter_flipxy)

            switch(yType)

                case 'groupby'
                    ylabel_with_space(curPlotHandle,{curInfoGby{g};curInfoStr});

                otherwise
                    ylabel_with_space(curPlotHandle,curInfoStr);
            end
            xlabel_with_space(curPlotHandle,curFeatureString);
        else


            switch(yType)

                case 'groupby'
                    ylabel_with_space(curPlotHandle,{curInfoGby{curUgroupIdx};curFeatureString});

                otherwise
                    ylabel_with_space(curPlotHandle,curFeatureString);
            end
            if(ExFNIRS.settings.plot_scatter_nonparametric)
                xlabel_with_space(curPlotHandle,sprintf('Rank %s',curInfoStr));
            else
                xlabel_with_space(curPlotHandle,curInfoStr);
            end
        end



        if(ExFNIRS.settings.plot_scatter_line||ExFNIRS.settings.plot_scatter_err)
            if(N>2)
                [coefficients,PolyS] = polyfit(xVals, yVals, 1);
                CI = pf2_base.external.polyparci(coefficients,PolyS);
                xFit = linspace(min(xVals), max(xVals), 1000);
                [yFit,deltaY] = polyval(coefficients, xFit,PolyS);

                if(ExFNIRS.settings.plot_scatter_extend)
                    curXlim=xlim(curPlotHandle);
                    xFitExtend = linspace(min(curXlim), max(curXlim), 1000);
                    yFitExtend = polyval(coefficients, xFitExtend);
                end

                errMulitply=ExFNIRS.settings.plot_bar_err_mult;
                %CI=[0,0;0,0];

                yEst=polyval(coefficients, xVals,PolyS);
                yDiff=yVals-yEst;
                SD=std(yDiff);

                %SD=sqrt(N)*(CI(:,2)-CI(:,1))'/3.92;
                SEM=SD/sqrt(N);

                switch(ExFNIRS.settings.plot_scatter_err_feature)
                    case 'SEM'
                        %yCI_Upper = polyval(coefficients+SEM*errMulitply, xFit);
                        %yCI_Lower = polyval(coefficients-SEM*errMulitply, xFit);
                        yCI_Upper = yFit+SEM*errMulitply;
                        yCI_Lower = yFit-SEM*errMulitply;
                    case 'SD'
                        %yCI_Upper = polyval(coefficients+SD*errMulitply, xFit);
                        %yCI_Lower = polyval(coefficients-SD*errMulitply, xFit);
                        yCI_Upper = yFit+SD*errMulitply;
                        yCI_Lower = yFit-SD*errMulitply;
                    case '95%CI'
                        yCI_Upper = polyval(CI(1,:), xFit);
                        yCI_Lower = polyval(CI(2,:), xFit);
                    case '50%PI'
                        yCI_Upper = yFit+deltaY*(tinv(0.50,(N-1)));
                        yCI_Lower = yFit-deltaY*(tinv(0.50,(N-1)));
                    case '67%PI'
                        yCI_Upper = yFit+deltaY*(tinv(0.67,(N-1)));
                        yCI_Lower = yFit-deltaY*(tinv(0.67,(N-1)));
                    case '90%PI'
                        yCI_Upper = yFit+deltaY*(tinv(0.90,(N-1)));
                        yCI_Lower = yFit-deltaY*(tinv(0.90,(N-1)));
                    case '95%PI'
                        yCI_Upper = yFit+deltaY*(tinv(0.95,(N-1)));
                        yCI_Lower = yFit-deltaY*(tinv(0.95,(N-1)));
                end
            end
        end



        if(ExFNIRS.settings.plot_scatter_err&&N>2)
            errStyle=ExFNIRS.settings.plot_scatter_error_style;

            plotShaded=false;

            switch(errStyle)
                case 'Dashed'
                    errStyle='--';
                    lineWidth=2;
                case 'Fine'
                    errStyle='-';
                    lineWidth=0.5;
                case 'Shaded'
                    errStyle='-';
                    lineWidth=0.5;
                    plotShaded=true;
                otherwise
                    error('Unspecified error style');
            end

            errColor=sColor+(1-sColor)*0.55;
            if(plotShaded)
                  errAlpha=0.15;
                  yPatch=[yCI_Lower,fliplr(yCI_Upper)];
                  xPatch=[xFit,fliplr(xFit)];
                  %xPatch(isnan(yPatch))=[];
                  %yPatch(isnan(yPatch))=[];

                  h=patch(curPlotHandle,xPatch,yPatch,-1,'facecolor',errColor,'edgecolor','none','facealpha',errAlpha);
                  set(h,'HandleVisibility','off');
                  set(h,'HitTest','off');
                  set(h.Annotation.LegendInformation,'IconDisplayStyle','off');
            end

            h=plot(curPlotHandle,xFit,yCI_Upper,'LineStyle',errStyle,'Color',errColor,'LineWidth',lineWidth);
            set(h.Annotation.LegendInformation,'IconDisplayStyle','off');
            h=plot(curPlotHandle,xFit,yCI_Lower,'LineStyle',errStyle,'Color',errColor,'LineWidth',lineWidth);
            set(h.Annotation.LegendInformation,'IconDisplayStyle','off');
        else

                   gAErrStrs{curGroupInfoIdx}=''; 

        end

        if(ExFNIRS.settings.plot_scatter_line&&N>2)
            hold(curPlotHandle,'on')
            if(ExFNIRS.settings.plot_scatter_extend)
                gaH=plot(curPlotHandle,xFitExtend, yFitExtend, 'r-', 'LineWidth', 2,'Color',sColor);
            else
                gaH=plot(curPlotHandle,xFit, yFit, 'r-', 'LineWidth', 2,'Color',sColor);
            end

            set(gaH.Annotation.LegendInformation,'IconDisplayStyle','off');

            [rho,pval] = corr(xVals,yVals,'Type','Spearman');


            [r,p]=corr(xVals,yVals,'Type','Pearson');


               fitStr=gbyStrs{g};
               gAStrs{curUgroupIdx}= fitStr;
               %if(ExFNIRS.settings.plot_legend_mode==3||(ExFNIRS.settings.plot_legend_mode==2&&lastSubPlot))
                   sH{curFigIdx(1),curFigIdx(2)}.legendHandles{curSy,curSx}.h{curUgroupIdx}=gaH;
               %end


            tagStr=sprintf('%s (N %i)\nRho=%.3f, p=%.4f\nr=%.3f p=%.4f',fitStr,N,rho,pval,r,p); 
            set(gaH,'tag',tagStr);
        elseif(~ExFNIRS.settings.plot_scatter_line)
            %sH{curFigIdx(1),curFigIdx(2)}.legendHandles{curSy,curSx}.h=cell(0);
            %gAStrs=cell(0);
        end


        curLgdHandles=sH{curFigIdx(1),curFigIdx(2)}.legendHandles{curSy,curSx}.h(:);
        numCurLgd=length(curLgdHandles);
        numFilled=0;
        for i=1:numCurLgd
            numFilled=numFilled+~isempty(curLgdHandles{i});
        end

        if(ExFNIRS.settings.ylim_fixed)
            ylim(curPlotHandle,'auto');
            cylim=ylim(curPlotHandle);
            ExFNIRS.settings.ylim_fixed_min=min(ExFNIRS.settings.ylim_fixed_min,cylim(1));
            ExFNIRS.settings.ylim_fixed_max=max(ExFNIRS.settings.ylim_fixed_max,cylim(2));

            xlim(curPlotHandle,'auto');
            cxlim=xlim(curPlotHandle);
            xlim_fixed_min=min(xlim_fixed_min,cxlim(1));
            xlim_fixed_max=max(xlim_fixed_max,cxlim(2));
        elseif(ExFNIRS.settings.ylim_manual)
            if(ExFNIRS.settings.plot_scatter_flipxy)
                if(~plotCount)
                    xlim(curPlotHandle,[ExFNIRS.settings.ylim_manual_min,ExFNIRS.settings.ylim_manual_max]);
                else
                    xlim(curPlotHandle,[0,ExFNIRS.settings.ylim_manual_max]);
                end
            else
                if(~plotCount)
                    ylim(curPlotHandle,[ExFNIRS.settings.ylim_manual_min,ExFNIRS.settings.ylim_manual_max]);
                else
                    ylim(curPlotHandle,[0,ExFNIRS.settings.ylim_manual_max]);
                end
            end
        elseif(plotCount)
            if(ExFNIRS.settings.plot_scatter_flipxy)
                cxlim=xlim(curPlotHandle);
                xlim(curPlotHandle,[0,cxlim(2)]);
            else
                cylim=ylim(curPlotHandle);
                ylim(curPlotHandle,[0,cylim(2)]);
            end

        else
            ylim(curPlotHandle,'auto');
        end
    end
           
 if(ExFNIRS.settings.plot_scatter_flipxy)
     temp=plotXstr;
    plotXstr=plotYstr;
    plotYstr=temp;

    temp=curUstrX;
    curUstrX=curUstrY;
    curUstrY=temp; 
 end
      

if(plotCount)
    if(ExFNIRS.settings.plot_scatter_flipxy)
        xlim_fixed_min=0;
    else
        ExFNIRS.settings.ylim_fixed_min=0; 
    end
end


for i=1:size(sH,1)
    for b=1:size(sH,2)
        for x=1:numSubX
            for y=1:numSubY
                if(ExFNIRS.settings.ylim_fixed)
                    ylim(sH{i,b}.subH{y,x},[ExFNIRS.settings.ylim_fixed_min,ExFNIRS.settings.ylim_fixed_max]);
                    xlim(sH{i,b}.subH{y,x},[xlim_fixed_min,xlim_fixed_max]);
                end
                
                if(plotXstr)
                    xlim(sH{i,b}.subH{y,x},[0,length(curUstrX)]+0.5);
                    xticks(sH{i,b}.subH{y,x},1:(length(curUstrX)));
                   xticklabels(sH{i,b}.subH{y,x},curUstrX); 
                   
                end

                if(plotYstr)
                    ylim(sH{i,b}.subH{y,x},[0,length(curUstrY)]+0.5);
                    yticks(sH{i,b}.subH{y,x},1:(length(curUstrY)));
                   yticklabels(sH{i,b}.subH{y,x},curUstrY); 
                   
                end
                
                if((ExFNIRS.settings.plot_legend_mode==3||(ExFNIRS.settings.plot_legend_mode==2&&(x==numSubX)&&y==numSubY))&&numUgroups>1)
                    lgStrs=[];
                    for k=1:length(pointStrs)
                       if(isnumeric(pointStrs{k}))
                           pointStrs{k}='';
                       end
                       lgStrs=[lgStrs;pointStrs(k)];
                    end

                    legend(sH{i,b}.subH{y,x},pointStrs(:),'Location', 'Best');
                end

                hold(sH{i,b}.subH{y,x},'off')
            end
        end

        addDebugAnnotation(sH{i,b}.h);
        
        curCorrstr=sprintf('%s vs. %s',curInfoVarX,curInfoVarY);
        
        
        
        
        if(ExFNIRS.settings.plot_scatter_nonparametric)
            suptStr=sprintf('Rank %s',curCorrstr);
        else
            suptStr=curCorrstr;
        end
        
        switch(xType)
            case 'groupby'
                suptitle_with_space(sprintf('%s by %s',suptStr,curInfoGroup));
            otherwise
                suptitle_with_space(suptStr);
        end
      
    end
end
