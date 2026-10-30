function out = octaveSubsetOps(op)
% OCTAVESUBSETOPS Headless operations shared by the Octave reference and runner
%
% Single definition of each operation checked by the Octave CI subset, so
% pf2_base.tests.generateOctaveReference (MATLAB) and
% pf2_base.tests.runOctaveSubset (Octave or MATLAB) run identical code.
%
% Reference:
%   Internal pf2 implementation.
%
% Syntax:
%   out = pf2_base.tests.octaveSubsetOps(op)
%
% Inputs:
%   op - 'devices' | 'import' | 'default' | 'pipeline' | 'epochs' | 'qc'
%
% Outputs:
%   out - For 'devices', a struct array (name, nChannels, wavelengths,
%         sdDistances, mni) for every shipped device that loads. For
%         'import', a struct (rawSize, rawSum, timeSum). For 'default' and
%         'pipeline', a struct (HbO, HbR) holding every 5th sample. For
%         'epochs', a struct (markerTimes, nBlocks, nSegments, avgTime,
%         avgHbO, nWindows) from getMarkers, defineBlocks, extractBlocks,
%         blockAverage and slidingWindows on the processed sample. For
%         'qc', a struct (pass, sci, cov) from pf2.qc.pipeline.assess.
%
% See also: pf2_base.tests.generateOctaveReference,
%           pf2_base.tests.runOctaveSubset

    root = pf2_base.pf2_defaultRootPath();
    switch op
        case 'devices'
            files = dir(fullfile(root, 'devices', '*.cfg'));
            names = sort({files.name});
            out = struct('name', {}, 'nChannels', {}, 'wavelengths', {}, ...
                'sdDistances', {}, 'mni', {});
            for k = 1:numel(names)
                name = regexprep(names{k}, '\.cfg$', '');
                try
                    dev = pf2.Device.load(name);
                catch
                    continue;
                end
                mni = [];
                if dev.hasMNI()
                    mni = dev.mniPositions();
                end
                out(end+1) = struct('name', name, 'nChannels', dev.nChannels, ...
                    'wavelengths', dev.wavelengths(), ...
                    'sdDistances', dev.sdDistances(), 'mni', mni); %#ok<AGROW>
            end

        case 'import'
            data = pf2.import.importNIR(fullfile(root, 'sampledata', 'sampleNIR.nir'));
            raw = data.raw;
            out = struct('rawSize', size(raw), 'rawSum', sum(raw(~isnan(raw))), ...
                'timeSum', sum(data.time));

        case 'default'
            proc = processFNIRS2(pf2.import.sampleData());
            out = struct('HbO', proc.HbO(1:5:end, :), 'HbR', proc.HbR(1:5:end, :));

        case 'pipeline'
            rp = pf2_base.RawPipeline('OctaveRefRaw');
            rp = rp.add('pf2_Intensity2OD');
            rp = rp.add('pf2_MotionCorrectTDDR');
            opPipe = pf2_base.OxyPipeline('OctaveRefOxy');
            opPipe = opPipe.add('pf2_lpf', struct('freq_cut', 0.1));
            opPipe = opPipe.add('pf2_hpf', struct('freq_cut', 0.01));
            ctx = pf2.ProcessingContext();
            ctx.rawMethod = rp.toMethod();
            ctx.oxyMethod = opPipe.toMethod();
            proc = ctx.process(pf2.import.sampleData());
            out = struct('HbO', proc.HbO(1:5:end, :), 'HbR', proc.HbR(1:5:end, :));

        case 'epochs'
            proc = processFNIRS2(pf2.import.sampleData());
            out = struct();
            out.markerTimes = pf2.data.getMarkers(proc, 50);
            blocks = pf2.data.defineBlocks(proc, 50, 15, 'Embed', false);
            out.nBlocks = numel(blocks);
            segments = pf2.data.extractBlocks(proc, blocks, 'PreTime', 5, ...
                'PostTime', 15, 'SetT0', true);
            out.nSegments = numel(segments);
            ga = pf2.data.blockAverage(segments);
            out.avgTime = ga.time;
            out.avgHbO = ga.HbO.Mean;
            windows = pf2.data.slidingWindows(proc, 'Length', 10, ...
                'Overlap', 0.5, 'Embed', false);
            out.nWindows = numel(windows);

        case 'qc'
            report = pf2.qc.pipeline.assess(pf2.import.sampleData(), ...
                'Checks', {'saturation', 'sci', 'cov'});
            out = struct('pass', double(report.pass), ...
                'sci', report.sci.values, 'cov', report.cov.values);

        otherwise
            error('pf2:tests:octaveSubsetOps:unknownOp', 'Unknown operation "%s".', op);
    end
end
