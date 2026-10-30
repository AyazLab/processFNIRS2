function ensureStatsFallbacks()
%ENSURESTATSFALLBACKS Put the stats-toolbox fallback shims on the path if needed.
%
%   Idempotently ensures the compat_shims folder (nanmean/nansum/... drop-in
%   replacements) is on the MATLAB path when the Statistics and Machine
%   Learning Toolbox is not installed. Call this at toolbox entry points
%   that run before pf2_initialize (e.g. importers / device loading) so the
%   nan* family resolves even on a toolbox-less machine.
%
%   The shims are added at the END of the path: when the toolbox IS
%   installed its own nan* functions are already visible, so this function
%   does nothing and the toolbox versions are always used.
%
%   Inputs:
%     (none)
%
%   Outputs:
%     (none)
%
%   Notes:
%     Self-healing and cheap: it re-checks each call (a string scan of the
%     path) so it correctly re-adds the shims if the path was reset
%     mid-session (restoredefaultpath / rmpath). It does NOT probe a single
%     nan* name as a proxy (a user's stray nanmean.m on the path would
%     otherwise mask the whole family) — it keys off the actual toolbox
%     capability instead.
%
%   See also: pf2_base.pf2_initialize, pf2_base.hasStatsToolbox

% Under GNU Octave, load the required packages and MATLAB-function shims
% first (no-op under MATLAB).
pf2_base.env.ensureOctaveCompat();

% When the toolbox is installed its own nan* functions are on the path and
% take precedence; nothing to add.
if pf2_base.hasStatsToolbox()
    return;
end

root    = pf2_base.pf2_defaultRootPath();
shimDir = fullfile(root, 'compat_shims');
% strfind rather than contains: this runs before the Octave shims exist.
if exist(shimDir, 'dir') == 7 && isempty(strfind([pathsep path pathsep], [pathsep shimDir pathsep]))
    addpath(shimDir, '-end');
end

end
