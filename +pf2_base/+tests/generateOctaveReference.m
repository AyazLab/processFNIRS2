function ref = generateOctaveReference(savePath)
% GENERATEOCTAVEREFERENCE Build the MATLAB reference used by the Octave CI subset
%
% Runs the headless operations exercised by pf2_base.tests.runOctaveSubset
% under MATLAB and saves their results, so the Octave job can check parity
% against MATLAB rather than only checking that the code runs. Re-run this
% under MATLAB whenever an intended change alters any of these results
% (device geometry, Beer-Lambert conversion, filters, TDDR).
%
% Reference:
%   Internal pf2 implementation.
%
% Syntax:
%   pf2_base.tests.generateOctaveReference()
%   ref = pf2_base.tests.generateOctaveReference(savePath)
%
% Inputs:
%   savePath - (optional) Output .mat path. Default:
%              +pf2_base/+tests/+data/octave_reference.mat
%
% Outputs:
%   ref - Struct saved to savePath (MAT -v7, readable by Octave) with fields:
%           devices  - struct array: name, nChannels, wavelengths,
%                      sdDistances, mni (empty when the device has no MNI)
%           import   - rawSize, rawSum, time sum for sampleNIR.nir
%           default  - HbO, HbR (every 5th sample) from processFNIRS2 with
%                      default methods on pf2.import.sampleData()
%           pipeline - HbO, HbR (every 5th sample) from Intensity2OD + TDDR
%                      and LPF 0.1 Hz + HPF 0.01 Hz through a ProcessingContext
%           epochs   - marker times, block/segment/window counts, and the
%                      trial-averaged HbO from the block-averaging recipe
%           qc       - per-channel pass flags, SCI and CoV values
%           matlabVersion, created
%
% Example:
%   pf2_base.tests.generateOctaveReference();
%
% See also: pf2_base.tests.runOctaveSubset

    root = pf2_base.pf2_defaultRootPath();
    if nargin < 1 || isempty(savePath)
        savePath = fullfile(root, '+pf2_base', '+tests', '+data', 'octave_reference.mat');
    end

    ref = struct();
    ref.devices = pf2_base.tests.octaveSubsetOps('devices');
    ref.import = pf2_base.tests.octaveSubsetOps('import');
    ref.default = pf2_base.tests.octaveSubsetOps('default');
    ref.pipeline = pf2_base.tests.octaveSubsetOps('pipeline');
    ref.epochs = pf2_base.tests.octaveSubsetOps('epochs');
    ref.qc = pf2_base.tests.octaveSubsetOps('qc');
    ref.matlabVersion = version();
    ref.created = char(datetime('now', 'Format', 'yyyy-MM-dd''T''HH:mm:ss'));

    save(savePath, '-struct', 'ref', '-v7');
    fprintf('Saved Octave reference to %s\n', savePath);
end
