function varargout=sampleData(name, varargin)
% SAMPLEDATA Load a bundled example fNIRS dataset for testing/tutorials
%
% Loads the default bundled fNIR Devices sample recording (fNIR1200, with
% event markers) so you can try the toolbox without supplying your own file.
% Returns a ready-to-process data struct. Additional named datasets are
% available as sibling functions in the sampleData namespace (call with
% parentheses), each covering a different device or workflow stage. They
% can also be requested by name, sampleData('fNIR2000'), which is the form
% that works under GNU Octave: there this function hides the sampleData
% namespace, so pf2.import.sampleData.fNIR2000() does not resolve.
%
% Syntax:
%   data = pf2.import.sampleData()                % default fNIR1200 recording
%   pf2.import.sampleData()                        % show channel-check GUI
%   pf2.import.sampleData.fNIR2000()               % fNIR Devices fNIR2000
%   pf2.import.sampleData.fNIR1200()               % fNIR Devices fNIR1200
%   pf2.import.sampleData.experiment()             % multi-condition experiment
%   pf2.import.sampleData.group()                  % grouped Experiment object
%   pf2.import.sampleData.Hitachi_ETG4000_3x5()    % Hitachi ETG-4000 (3x5)
%   pf2.import.sampleData.Hitachi_ETG4000_3x11()   % Hitachi ETG-4000 (3x11)
%   data = pf2.import.sampleData('fNIR2000')       % same, by name (MATLAB and Octave)
%   [ex, allData] = pf2.import.sampleData('group', 'GroupBy', {'Condition'})
%
% Inputs:
%   name     - (optional) Dataset name: 'fNIR2000', 'fNIR1200', 'experiment',
%              'group', 'Hitachi_ETG4000_3x5' or 'Hitachi_ETG4000_3x11'.
%              Omit for the default fNIR1200 recording.
%   varargin - Arguments passed to the named dataset function.
%
% Outputs:
%   varargout - Without a name: the fNIRS data struct below. With a name:
%               the named dataset function's outputs.
%   fNIR - fNIRS data struct (.raw, .time, .fs, .fchMask, .markers, .info,
%          .device) ready to pass to processFNIRS2. With no output argument
%          the channel-check GUI is shown; with an output it loads headless.
%
% Example:
%   % Import, process, and plot the sample recording
%   data = pf2.import.sampleData();
%   processed = processFNIRS2(data);
%   pf2.data.plot.oxy(processed);
%
% See also: processFNIRS2, pf2.import.importNIR,
%           pf2.import.sampleData.fNIR2000, pf2.import.sampleData.experiment

if nargin >= 1
    datasets = {'fNIR2000', 'fNIR1200', 'experiment', 'group', ...
        'Hitachi_ETG4000_3x5', 'Hitachi_ETG4000_3x11'};
    idx = find(strcmpi(char(name), datasets), 1);
    if isempty(idx)
        error('pf2:import:sampleData:unknownDataset', ...
            'Unknown sample dataset "%s". Available: %s.', char(name), strjoin(datasets, ', '));
    end
    fn = ['pf2.import.sampleData.' datasets{idx}];
    if nargout == 0
        feval(fn, varargin{:});
    else
        [varargout{1:nargout}] = feval(fn, varargin{:});
    end
    return;
end

[filepath]=mfilename('fullpath');

slashes=find(filepath'=='/'|filepath'=='\');
filepath=filepath(1:slashes(end)); %strip filename

nirfilepath=sprintf('%s../../sampledata/sampleNIR.nir',filepath);
mrkfilepath=sprintf('%s../../sampledata/sampleNIR.mrk',filepath);

if(nargout>0)
	varargout{1}=pf2.import.importNIR(nirfilepath,mrkfilepath,false); % just load data
else
	varargout{1}=pf2.import.importNIR(nirfilepath,mrkfilepath,true); % show GUI; sets ans
end