function ensureOctaveCompat()
% ENSUREOCTAVECOMPAT Load Octave packages and MATLAB-function shims under Octave
%
% One-time setup for running the headless processing path under GNU Octave.
% Under MATLAB this returns immediately. Under Octave it loads the community
% packages the toolbox relies on (datatypes for table/datetime/categorical/
% string; signal and statistics for filtering and nan* reductions) and adds
% compat_shims/octave, which supplies MATLAB functions core Octave lacks
% (contains, strip, strlength, extractAfter/extractBefore, isStringScalar,
% and the two-argument form of round). Missing packages are reported once
% with a warning; the shims are still added.
%
% Called from pf2_base.ensureStatsFallbacks, which runs at the importer,
% device-loading, and pf2_base.pf2_initialize entry points. An explicit call
% is needed only before using other parts of the API in a fresh Octave
% session.
%
% Reference:
%   Internal pf2 implementation. Packages from https://packages.octave.org
%   (install with pkg install -forge datatypes signal statistics).
%
% Syntax:
%   pf2_base.env.ensureOctaveCompat()
%
% Inputs:
%   (none)
%
% Outputs:
%   (none)
%
% Example:
%   % Fresh Octave session
%   addpath('/path/to/processFNIRS2');
%   pf2_base.env.ensureOctaveCompat();
%   data = pf2.import.importNIR('sampledata/sampleNIR.nir');
%
% See also: pf2_base.env.isOctave, pf2_base.env.runtime,
%           pf2_base.ensureStatsFallbacks

    persistent done
    if ~isempty(done) || ~pf2_base.env.isOctave()
        return;
    end
    done = true;

    missing = {};
    pkgs = {'datatypes', 'signal', 'statistics'};
    for k = 1:numel(pkgs)
        try
            pkg('load', pkgs{k});  %#ok<*PKG> Octave-only built-in
        catch
            missing{end+1} = pkgs{k}; %#ok<AGROW>
        end
    end
    if ~isempty(missing)
        warning('pf2:env:missingPackages', ...
            ['Octave packages not available: %s. Install with ' ...
             'pkg install -forge %s'], strjoin(missing, ', '), strjoin(missing, ' '));
    end

    % Shims go at the end of the path so package-provided functions win.
    % The round shim intentionally shadows the built-in; silence that
    % one-time notice.
    shimDir = fullfile(pf2_base.pf2_defaultRootPath(), 'compat_shims', 'octave');
    if exist(shimDir, 'dir') == 7
        prev = warning('off', 'Octave:shadowed-function');
        addpath(shimDir, '-end');
        warning(prev);
    end
end
