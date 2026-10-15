function nFailed = runOctaveSubset()
% RUNOCTAVESUBSET Plain-function test lane for the GNU Octave CI job
%
% Octave does not implement matlab.unittest, so the classdef suite cannot
% run there. This runner checks the headless path that is supported under
% Octave: package loading, the INI reader/writer, device loading, import,
% default processing, the Pipeline API through a ProcessingContext, the
% block-averaging recipe (markers, blocks, epochs, averages, sliding
% windows), and the QC pipeline.
% Numerical results are compared with a MATLAB reference
% (+pf2_base/+tests/+data/octave_reference.mat, built by
% pf2_base.tests.generateOctaveReference), so the lane checks parity with
% MATLAB as well as that the code runs. It also runs under MATLAB, where it
% checks the reference is current.
%
% Under Octave, the root pf2.m (the GUI launcher) shadows the +pf2 package,
% so it must not be on the path; the CI job removes it from its checkout.
%
% Reference:
%   Internal pf2 implementation.
%
% Syntax:
%   pf2_base.tests.runOctaveSubset()
%   nFailed = pf2_base.tests.runOctaveSubset()
%
% Inputs:
%   (none)
%
% Outputs:
%   nFailed - Number of failed checks. With no output requested, the
%             function errors when any check fails, so `octave-cli --eval`
%             and `matlab -batch` exit non-zero.
%
% Example:
%   octave-cli --eval "addpath(pwd); pf2_base.tests.runOctaveSubset()"
%
% See also: pf2_base.tests.generateOctaveReference,
%           pf2_base.tests.octaveSubsetOps, pf2_base.env.ensureOctaveCompat

    pf2_base.env.ensureOctaveCompat();
    root = pf2_base.pf2_defaultRootPath();
    ref = load(fullfile(root, '+pf2_base', '+tests', '+data', 'octave_reference.mat'));
    tol = 1e-9;   % relative to the reference's largest magnitude

    results = {};
    results{end+1} = check('runtime packages', @() checkRuntime());
    results{end+1} = check('pf2 package resolves', @() checkPackage());
    results{end+1} = check('INI round trip', @() checkINI(root));
    results{end+1} = check('round/contains shims', @() checkShims());
    results{end+1} = check('device geometry', @() checkDevices(ref.devices, tol));
    results{end+1} = check('importNIR', @() checkImport(ref.import));
    results{end+1} = check('processFNIRS2 default', @() checkHb(ref.default, 'default', tol));
    results{end+1} = check('Pipeline API via ProcessingContext', @() checkHb(ref.pipeline, 'pipeline', tol));
    results{end+1} = check('ProcessingContext copy/validation', @() checkContext());
    results{end+1} = check('markers, blocks, epochs, averaging, windows', @() checkEpochs(ref.epochs, tol));
    results{end+1} = check('QC pipeline (saturation, SCI, CoV)', @() checkQC(ref.qc, tol));

    ok = cellfun(@(r) r, results);
    info = pf2_base.env.runtime();
    fprintf('\n%d of %d checks passed under %s %s.\n', sum(ok), numel(ok), ...
        info.name, info.version);
    nFailed = sum(~ok);
    if nargout == 0 && nFailed > 0
        error('pf2:tests:runOctaveSubset:failed', '%d Octave subset check(s) failed.', nFailed);
    end
end

function ok = check(name, fn)
% CHECK Run one check, print PASS/FAIL with the first error line.
    try
        fn();
        ok = true;
        fprintf('PASS  %s\n', name);
    catch err
        ok = false;
        msg = strtok(err.message, char(10));
        fprintf('FAIL  %s: %s\n', name, msg);
        for k = 1:min(3, numel(err.stack))
            fprintf('        at %s:%d\n', err.stack(k).name, err.stack(k).line);
        end
    end
end

function checkRuntime()
    info = pf2_base.env.runtime();
    assert(isempty(info.missingPkgs), 'missing packages: %s', strjoin(info.missingPkgs, ', '));
end

function checkPackage()
    % Fails under Octave when root pf2.m is on the path.
    w = which('pf2');
    assert(~pf2_base.env.isOctave() || isempty(w) || isempty(strfind(w, 'pf2.m')), ...
        'root pf2.m is on the path and shadows the +pf2 package under Octave');
    assert(isa(pf2.Device.load('fNIR_Devices_fNIR2000'), 'pf2.Device'), ...
        'pf2.Device.load did not return a pf2.Device');
end

function checkINI(root)
    c = pf2_base.external.INI('File', fullfile(root, 'devices', 'fNIR_Devices_fNIR2000.cfg'));
    c.read();
    assert(ismember('Info', c.Sections), 'Info section missing');
    c.add('Octave Check', struct('a', 1, 'b', {{'x', 'y'}}));
    f = [tempname() '.ini'];
    cleanup = onCleanup(@() deleteIfExists(f));
    c.write(f);
    r = pf2_base.external.INI('File', f);
    r.read();
    assert(isequal(sort(r.Sections), sort(c.Sections)), 'sections differ after round trip');
    assert(isequal(r.get('Octave Check'), c.get('Octave Check')), 'section data differs after round trip');
end

function checkShims()
    assert(isequal(round([0.285 1.005 -2.675], 2), [0.29 1.01 -2.68]), 'round(x, n) ties');
    assert(round(2.4999999999999996, 0) == 2, 'round(x, 0) near tie');
    hits = contains({'Abc', 'x'}, 'a', 'IgnoreCase', true);
    assert(contains('abc', '') && isequal(hits, [true false]), 'contains');
end

function checkDevices(refDevices, tol)
    got = pf2_base.tests.octaveSubsetOps('devices');
    gotNames = {got.name};
    for k = 1:numel(refDevices)
        r = refDevices(k);
        idx = find(strcmp(gotNames, r.name), 1);
        assert(~isempty(idx), 'device %s did not load', r.name);
        g = got(idx);
        assert(isequal(g.nChannels, r.nChannels), '%s: nChannels differs', r.name);
        assertClose(g.wavelengths, r.wavelengths, tol, [r.name ' wavelengths']);
        assertClose(g.sdDistances, r.sdDistances, tol, [r.name ' sdDistances']);
        assertClose(g.mni, r.mni, tol, [r.name ' MNI positions']);
    end
end

function checkImport(r)
    g = pf2_base.tests.octaveSubsetOps('import');
    assert(isequal(g.rawSize, r.rawSize), 'raw size differs');
    assertClose(g.rawSum, r.rawSum, 1e-12, 'raw sum');
    assertClose(g.timeSum, r.timeSum, 1e-12, 'time sum');
end

function checkHb(r, op, tol)
    g = pf2_base.tests.octaveSubsetOps(op);
    assertClose(g.HbO, r.HbO, tol, [op ' HbO']);
    assertClose(g.HbR, r.HbR, tol, [op ' HbR']);
end

function checkEpochs(r, tol)
    g = pf2_base.tests.octaveSubsetOps('epochs');
    assertClose(g.markerTimes, r.markerTimes, tol, 'marker times');
    assert(g.nBlocks == r.nBlocks, 'block count %d, expected %d', g.nBlocks, r.nBlocks);
    assert(g.nSegments == r.nSegments, 'segment count %d, expected %d', g.nSegments, r.nSegments);
    assert(g.nWindows == r.nWindows, 'window count %d, expected %d', g.nWindows, r.nWindows);
    assertClose(g.avgTime, r.avgTime, tol, 'averaged time base');
    assertClose(g.avgHbO, r.avgHbO, tol, 'averaged HbO');
end

function checkQC(r, tol)
    g = pf2_base.tests.octaveSubsetOps('qc');
    assert(isequal(g.pass, r.pass), 'per-channel pass flags differ');
    assertClose(g.sci, r.sci, tol, 'SCI values');
    assertClose(g.cov, r.cov, tol, 'CoV values');
end

function checkContext()
    ctx = pf2.ProcessingContext('SubjectAge', 30);
    c2 = ctx.copy();
    c2.subjectAge = 40;
    assert(ctx.subjectAge == 30 && c2.subjectAge == 40, 'copy() is not independent');
    assert(isa(c2, 'pf2.ProcessingContext'), 'copy() changed the class');
    rejected = false;
    try
        ctx.dpfMode = 'Bogus';
    catch
        rejected = true;
    end
    assert(rejected, 'invalid dpfMode was accepted');
    ctx.ppf = [6; 7];
    assert(isequal(size(ctx.ppf), [1 2]), 'ppf column was not reshaped to a row');
end

function assertClose(got, want, tol, label)
    assert(isequal(size(got), size(want)), '%s: size %s, expected %s', label, ...
        mat2str(size(got)), mat2str(size(want)));
    if isempty(want)
        return;
    end
    nanGot = isnan(got);
    assert(isequal(nanGot, isnan(want)), '%s: NaN pattern differs', label);
    scale = max(abs(want(~nanGot)));
    if isempty(scale) || scale == 0
        scale = 1;
    end
    err = max(abs(got(~nanGot) - want(~nanGot)));
    if isempty(err)
        err = 0;
    end
    assert(err <= tol * scale, '%s: max abs difference %.3g exceeds %.3g', label, err, tol * scale);
end

function deleteIfExists(f)
    if exist(f, 'file') == 2
        delete(f);
    end
end
