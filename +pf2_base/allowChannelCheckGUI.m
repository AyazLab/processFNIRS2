function tf = allowChannelCheckGUI()
% ALLOWCHANNELCHECKGUI True when it is safe to show the channel-check GUI
%
% Single gate used by the import path before launching the interactive
% channel-quality GUI (probeCheckGUI / pf2.qc.ChannelCheck). Returns false
% whenever a blocking window must not appear, so unattended runs proceed with
% a saved mask or an all-good default instead of hanging.
%
% Syntax:
%   tf = pf2_base.allowChannelCheckGUI()
%
% Outputs:
%   tf - Logical scalar; true only if ALL of the following hold:
%        - the GUI has not been disabled via pf2_base.channelCheckGUIEnabled,
%        - the session is interactive (not headless, see pf2_base.isHeadless),
%        - execution is not inside the matlab.unittest test framework.
%
% Algorithm:
%   ANDs the explicit enable flag with two safety probes: display
%   availability (isHeadless) and a dbstack scan for the test framework, so
%   tests never trigger the GUI even when run from an interactive desktop.
%
% Example:
%   if pf2_base.allowChannelCheckGUI()
%       fNIR = probeCheckGUI(fNIR, filename);
%   else
%       fNIR.fchMask = ones(1, fNIR.device.nChannels);
%   end
%
% See also: pf2_base.channelCheckGUIEnabled, pf2_base.isHeadless,
%           pf2_base.loadExistingMaskOrCheck

    tf = pf2_base.channelCheckGUIEnabled() ...
        && ~pf2_base.isHeadless() ...
        && ~pf2_base.underTestFramework();
end
