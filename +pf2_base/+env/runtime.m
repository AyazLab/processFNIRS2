function info = runtime()
% RUNTIME Describe the interpreter runtime and missing optional packages
%
% Returns a struct identifying the host interpreter (MATLAB or Octave), its
% version string, and any optional packages required by the headless
% processing path that are not currently available. Intended for one-time
% startup diagnostics and CI logging rather than per-call branching; use
% pf2_base.env.isOctave for hot-path checks.
%
% Reference:
%   Internal pf2 implementation.
%
% Syntax:
%   info = pf2_base.env.runtime()
%
% Inputs:
%   (none)
%
% Outputs:
%   info - Struct with fields:
%            name        - 'MATLAB' or 'Octave'
%            version     - Version string from version()
%            isOctave    - Logical scalar (see pf2_base.env.isOctave)
%            missingPkgs - Cellstr of required-but-unavailable packages.
%                          On Octave, checks 'datatypes' (table/datetime/
%                          categorical/string), 'signal' (pwelch and other
%                          spectral estimators), and 'statistics' (nan*
%                          reductions). Empty on MATLAB or when all
%                          required packages are present.
%
% Example:
%   r = pf2_base.env.runtime();
%   fprintf('Runtime: %s %s\n', r.name, r.version);
%   if ~isempty(r.missingPkgs)
%       warning('pf2:env:missingPackages', ...
%           'Missing Octave packages: %s', strjoin(r.missingPkgs, ', '));
%   end
%
% See also: pf2_base.env.isOctave

    info = struct();
    info.isOctave    = pf2_base.env.isOctave();
    info.version     = version();
    info.missingPkgs = {};

    if info.isOctave
        info.name = 'Octave';
        % Packages the headless processing path depends on.
        required = {'datatypes', 'signal', 'statistics'};
        for k = 1:numel(required)
            if ~localHasOctavePackage(required{k})
                info.missingPkgs{end+1} = required{k};
            end
        end
    else
        info.name = 'MATLAB';
    end
end

%%_Subfunctions_________________________________________________________

function tf = localHasOctavePackage(name)
% LOCALHASOCTAVEPACKAGE Return true if a named Octave package is installed
%
% Inputs:
%   name - Package name (char), e.g. 'signal'
%
% Outputs:
%   tf - Logical scalar; true when pkg reports the package as installed

    tf = false;
    try
        lst = pkg('list', name);  %#ok<*PKG> Octave-only built-in
        tf = ~isempty(lst);
    catch
        tf = false;
    end
end
