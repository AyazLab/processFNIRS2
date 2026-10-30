function fNIR=loadExistingMaskOrCheck(fNIR,nirFilename,channelCheckVersion)
% LOADEXISTINGMASKORCHECK Load saved channel mask or launch quality check GUI
%
% Checks for a previously saved channel mask file (*_CH.mat) associated
% with the given fNIRS recording. If found, loads the mask into fchMask.
% Otherwise, launches the channel quality check GUI (probeCheckGUI or
% ChannelCheck) for interactive channel rejection.
%
% Syntax:
%   fNIR = pf2_base.loadExistingMaskOrCheck(fNIR)
%   fNIR = pf2_base.loadExistingMaskOrCheck(fNIR, nirFilename)
%   fNIR = pf2_base.loadExistingMaskOrCheck(fNIR, nirFilename, channelCheckVersion)
%
% Inputs:
%   fNIR                - fNIRS data structure [struct]
%                         Must contain info.filename if nirFilename is omitted.
%   nirFilename         - (optional) Full path to the original recording file.
%                         Used to locate the *_CH.mat sidecar. If omitted,
%                         reads from fNIR.info.filename.
%   channelCheckVersion - (optional) Which GUI to launch when no saved mask
%                         exists. 1 = probeCheckGUI (legacy GUIDE),
%                         2 = pf2.qc.ChannelCheck (App Designer). Defaults
%                         to the highest version supported by the running
%                         MATLAB installation (see
%                         pf2_base.channelCheckVersion).
%
% Outputs:
%   fNIR - fNIRS structure with fchMask field updated [struct]
%          Values: 1 = good, 0.5 = marginal, 0 = rejected.
%
% Algorithm:
%   1. Derive *_CH.mat path from nirFilename (or fNIR.info.filename)
%   2. If *_CH.mat exists, load and search for any field containing 'mask'
%   3. If found, assign to fNIR.fchMask and return
%   4. Otherwise, launch the selected channel check GUI
%
% Example:
%   data = pf2.import.importNIR('recording.nir');
%   data = pf2_base.loadExistingMaskOrCheck(data);
%
% See also: pf2.qc.ChannelCheck, probeCheckGUI

	if(nargin<2||isempty(nirFilename))
		if(pf2_base.isnestedfield(fNIR,'info.filename'))
		   nirFilename=fNIR.info.filename;
		else
		   error('pf2_base:loadExistingMaskOrCheck:noFilename', 'No filename found');
		end
	end
	if nargin < 3 || isempty(channelCheckVersion)
		channelCheckVersion = pf2_base.channelCheckVersion();
	end

	if(~isempty(nirFilename))
		[pathstr, name, ext] = fileparts(nirFilename);
		if(length(pathstr)>0)
			filestr=[pathstr,'/',name,'_CH.mat'];
		else
			filestr=[name,'_CH.mat'];
        end

        if exist(filestr, 'file') == 2
			chMaskFile=load(filestr);

            maskFields=fieldnames(chMaskFile);

            potentiallyValidMasks=find(contains(lower(maskFields),'mask'));
            % Just accept anything that says mask
            for m=1:length(potentiallyValidMasks)
                potentialField=chMaskFile.(maskFields{potentiallyValidMasks(m)});
                if(isnumeric(potentialField))
                    fNIR.fchMask=potentialField;
                    fprintf('Channel mask loaded from: %s\n',filestr);
                    fprintf('%i channels rejected, %i channels marked noisy\n',(sum(fNIR.fchMask==0)),sum(fNIR.fchMask==0.5));
                    fNIR=setQcStatus(fNIR,'mask_loaded');
                    return;
                end

            end

        end

		% Never open a blocking GUI when it cannot/should not be shown
		% (headless session, or running under the test framework, or the GUI
		% disabled via pf2_base.channelCheckGUIEnabled). Default to all
		% channels good and warn LOUDLY so the run proceeds unattended but the
		% analyst knows channels were NOT reviewed. fNIR.info.qcStatus records
		% this so downstream code can distinguish it from a reviewed mask.
		if ~pf2_base.allowChannelCheckGUI()
			if isempty(fNIR.fchMask)
				fNIR.fchMask = defaultMask(fNIR);
			end
			warning('pf2:loadExistingMaskOrCheck:guiSuppressed', ...
				['No saved channel mask for "%s" and the channel-check GUI is ', ...
				 'unavailable/suppressed (headless, under test, or disabled): ', ...
				 'defaulting to ALL CHANNELS GOOD. Bad/saturated channels will ', ...
				 'NOT be rejected. Run pf2.qc.pipeline.assess + pf2.qc.pipeline.apply, ', ...
				 'or save a *_CH.mat sidecar via pf2.qc.ChannelCheck, before analysis.'], name);
			fNIR=setQcStatus(fNIR,'unreviewed_default');
			return;
		end

		if channelCheckVersion == 2
			app = pf2.qc.ChannelCheck(fNIR, ...
				'CalledFromImport', true, 'SkipConfirmation', true);
			if isvalid(app)
				fNIR = app.OutputData;
				delete(app);
			end
		else
			fNIR=probeCheckGUI(fNIR,nirFilename);
		end
		fNIR=setQcStatus(fNIR,'gui_reviewed');

	end


end

%%_Subfunctions_________________________________________________________

function fNIR = setQcStatus(fNIR, status)
% SETQCSTATUS Record how the channel mask was determined, for audit/provenance
%   'mask_loaded'        - loaded from a saved *_CH.mat sidecar
%   'gui_reviewed'       - reviewed interactively via the channel-check GUI
%   'unreviewed_default' - GUI suppressed; defaulted to all channels good
	if ~isfield(fNIR, 'info') || ~isstruct(fNIR.info)
		fNIR.info = struct();
	end
	fNIR.info.qcStatus = status;
end

function mask = defaultMask(fNIR)
% DEFAULTMASK All-good channel mask sized from the device channel count
	mask = [];
	try
		if isfield(fNIR, 'device') && ~isempty(fNIR.device)
			mask = ones(1, fNIR.device.nChannels);
		else
			dev = pf2.Device.load(fNIR);
			mask = ones(1, dev.nChannels);
		end
	catch
		warning('pf2:loadExistingMaskOrCheck:unknownChannelCount', ...
			'Cannot determine channel count for default fchMask; left empty.');
	end
end