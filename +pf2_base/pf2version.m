function [outStr,pf2ver,dateStr]=pf2version()
% PF2VERSION Return processFNIRS2 version information
%
% Returns version string, version number, and build date for the current
% processFNIRS2 installation. When called with no outputs, prints version
% information to the console.
%
% Syntax:
%   pf2version()
%   outStr = pf2version()
%   [outStr, pf2ver, dateStr] = pf2version()
%
% Inputs:
%   None
%
% Outputs:
%   outStr  - Formatted version string containing release and date info
%             Example: 'processFNIRS2 Release v0.9\nBuild Date: January 23 2026'
%   pf2ver  - Version number string (e.g., 'v0.9')
%   dateStr - Build date string (e.g., 'January 23 2026')
%
% Example:
%   % Display version to console
%   pf2version();
%
%   % Get version programmatically
%   [~, ver, date] = pf2version();
%   fprintf('Running version %s built on %s\n', ver, date);
%
% See also: pf2_initialize, processFNIRS2

pf2ver='v1.2.1';
dateStr='October 16 2026';


verString=sprintf('processFNIRS2 Release %s\n',pf2ver);
verString=sprintf('%sBuild Date: %s\n',verString,dateStr);

if(nargout==0)
	fprintf(verString);
	return;
else
	outStr=verString;
	return;
end
