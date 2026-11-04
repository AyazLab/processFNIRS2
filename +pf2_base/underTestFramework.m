function tf = underTestFramework()
% UNDERTESTFRAMEWORK True when called from inside the matlab.unittest framework
%
% Used to keep interactive windows (the processFNIRS2 GUI, the channel-check
% GUI) from opening while tests run, including tests run from an interactive
% desktop session, where a window left open would stall the test run.
%
% Syntax:
%   tf = pf2_base.underTestFramework()
%
% Outputs:
%   tf - Logical scalar; true when a function of the MATLAB test framework
%        is on the call stack.
%
% Algorithm:
%   Scans dbstack('-completenames') for a file under a 'testframework'
%   folder of the MATLAB installation.
%
% See also: pf2_base.allowChannelCheckGUI, pf2_base.isHeadless, processFNIRS2

tf = false;
try
    st = dbstack('-completenames');
    files = {st.file};
    marker = [filesep 'testframework' filesep];
    tf = any(contains(files, marker));
catch
end
end
