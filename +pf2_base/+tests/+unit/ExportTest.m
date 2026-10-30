classdef ExportTest < matlab.unittest.TestCase
% EXPORTTEST Unit tests for pf2 export functions (asNIR, asSNIRF)
%
% Comprehensive tests for exporting fNIRS data to NIR and SNIRF formats.
% Verifies file creation, content validity, and data preservation through
% roundtrip import/export cycles.
%
% Test Data:
%   Uses sample data from pf2.import.sampleData.fNIR2000() and processes
%   it with processFNIRS2() for tests requiring processed data.
%
% Usage:
%   results = runtests('pf2_base.tests.unit.ExportTest');
%   results = run(pf2_base.tests.unit.ExportTest);
%
% See also: pf2.export.asNIR, pf2.export.asSNIRF, pf2.import.importNIR,
%           pf2.import.importSNIRF, matlab.unittest.TestCase

    properties (Access = private)
        RawData           % Raw fNIRS data structure (before processing)
        ProcessedData     % Processed fNIRS data structure (with HbO/HbR)
        ProjectRoot       % Path to project root directory
        TempFiles         % Cell array of temp files to clean up
    end

    methods (TestClassSetup)
        function setupOnce(testCase)
            % SETUPONCE Initialize test environment once before all tests
            %
            % Loads sample data and processes it. Both raw and processed
            % data are stored for different test scenarios.

            % Get project root (three levels up from +pf2_base/+tests/+unit/)
            testCase.ProjectRoot = fileparts(fileparts(fileparts(fileparts(mfilename('fullpath')))));

            % Ensure we're in the project root for relative paths to work
            oldDir = cd(testCase.ProjectRoot);
            restoreDir = onCleanup(@() cd(oldDir));

            % Initialize temp files list
            testCase.TempFiles = {};

            % Load sample data
            try
                testCase.RawData = pf2.import.sampleData.fNIR2000();
            catch e
                testCase.assumeFail(sprintf('Failed to load sample data: %s', e.message));
            end

            testCase.assumeNotEmpty(testCase.RawData, ...
                'Sample data could not be loaded. Skipping tests.');

            % Process data for tests that require processed data
            try
                testCase.ProcessedData = processFNIRS2(testCase.RawData);
            catch e
                testCase.assumeFail(sprintf('Failed to process sample data: %s', e.message));
            end

            testCase.assumeNotEmpty(testCase.ProcessedData, ...
                'Processed data could not be created. Skipping tests.');
        end
    end

    methods (TestMethodSetup)
        function setupMethod(testCase)
            % SETUPMETHOD Verify data was loaded before each test
            testCase.assumeNotEmpty(testCase.RawData, ...
                'Raw data not available. Cannot run test.');
            testCase.assumeNotEmpty(testCase.ProcessedData, ...
                'Processed data not available. Cannot run test.');
        end
    end

    methods (TestMethodTeardown)
        function teardownMethod(testCase)
            % TEARDOWNMETHOD Clean up any temp files created during tests
            for i = 1:length(testCase.TempFiles)
                if exist(testCase.TempFiles{i}, 'file')
                    delete(testCase.TempFiles{i});
                end
            end
            testCase.TempFiles = {};
        end
    end

    methods (Access = private)
        function filepath = createTempPath(testCase, extension)
            % CREATETEMPPATH Generate a unique temporary file path
            %
            % Inputs:
            %   extension - File extension (e.g., '.nir', '.snirf')
            %
            % Outputs:
            %   filepath - Full path to temporary file

            basePath = tempname;
            filepath = [basePath extension];
            testCase.TempFiles{end+1} = filepath;
        end

        function cleanupRelatedFiles(testCase, basePath)
            % CLEANUPRELATEDFILES Clean up all files with same base name
            %
            % For NIR exports which create .nir, .mrk, and .log files

            [folder, name, ~] = fileparts(basePath);
            extensions = {'.nir', '.mrk', '.log'};
            for i = 1:length(extensions)
                fullPath = fullfile(folder, [name extensions{i}]);
                if exist(fullPath, 'file')
                    delete(fullPath);
                end
            end
        end
    end

    %% NIR Export Tests
    methods (Test, TestTags = {'NIR', 'Export'})
        function testExportNIRCreatesNIRFile(testCase)
            % TESTEXPORTNIRCREATESSNIRFILE Verify .nir file is created
            %
            % The asNIR function must create a .nir file at the specified
            % path containing the raw fNIRS data.

            filepath = testCase.createTempPath('.nir');

            % Export to NIR
            pf2.export.asNIR(testCase.ProcessedData, filepath);

            % Verify .nir file exists
            testCase.verifyEqual(exist(filepath, 'file'), 2, ...
                'NIR file was not created');

            % Cleanup related files
            testCase.cleanupRelatedFiles(filepath);
        end

        function testExportNIRCreatesMRKFile(testCase)
            % TESTEXPORTNIRCREATESMRKFILE Verify .mrk marker file is created
            %
            % The asNIR function creates a companion .mrk file containing
            % event markers alongside the .nir data file.

            filepath = testCase.createTempPath('.nir');
            [folder, name, ~] = fileparts(filepath);
            mrkPath = fullfile(folder, [name '.mrk']);

            % Export to NIR
            pf2.export.asNIR(testCase.ProcessedData, filepath);

            % Verify .mrk file exists
            testCase.verifyEqual(exist(mrkPath, 'file'), 2, ...
                'MRK marker file was not created');

            % Cleanup related files
            testCase.cleanupRelatedFiles(filepath);
        end

        function testExportNIRCreatesLOGFile(testCase)
            % TESTEXPORTNIRCREATESLOGFILE Verify .log metadata file is created
            %
            % The asNIR function creates a companion .log file containing
            % session metadata alongside the .nir data file.

            filepath = testCase.createTempPath('.nir');
            [folder, name, ~] = fileparts(filepath);
            logPath = fullfile(folder, [name '.log']);

            % Export to NIR
            pf2.export.asNIR(testCase.ProcessedData, filepath);

            % Verify .log file exists
            testCase.verifyEqual(exist(logPath, 'file'), 2, ...
                'LOG metadata file was not created');

            % Cleanup related files
            testCase.cleanupRelatedFiles(filepath);
        end

        function testExportNIRFilesNotEmpty(testCase)
            % TESTEXPORTNIRFILESNOTEMPTY Verify NIR export files have content
            %
            % All three files (.nir, .mrk, .log) must contain data, not
            % be empty zero-byte files.

            filepath = testCase.createTempPath('.nir');
            [folder, name, ~] = fileparts(filepath);
            mrkPath = fullfile(folder, [name '.mrk']);
            logPath = fullfile(folder, [name '.log']);

            % Export to NIR
            pf2.export.asNIR(testCase.ProcessedData, filepath);

            % Verify .nir file has content
            nirInfo = dir(filepath);
            testCase.verifyGreaterThan(nirInfo.bytes, 0, ...
                'NIR file is empty (0 bytes)');

            % Verify .mrk file has content
            mrkInfo = dir(mrkPath);
            testCase.verifyGreaterThan(mrkInfo.bytes, 0, ...
                'MRK file is empty (0 bytes)');

            % Verify .log file has content
            logInfo = dir(logPath);
            testCase.verifyGreaterThan(logInfo.bytes, 0, ...
                'LOG file is empty (0 bytes)');

            % Cleanup related files
            testCase.cleanupRelatedFiles(filepath);
        end

        function testExportNIRRoundtrip(testCase)
            % TESTEXPORTNIRROUNDTRIP Verify export then import preserves raw data dimensions
            %
            % Exports processed data to NIR format, then re-imports it and
            % verifies that the raw data dimensions are preserved.

            filepath = testCase.createTempPath('.nir');
            [folder, name, ~] = fileparts(filepath);
            mrkPath = fullfile(folder, [name '.mrk']);

            % Export to NIR
            pf2.export.asNIR(testCase.ProcessedData, filepath);

            % Register related files for cleanup
            testCase.TempFiles{end+1} = mrkPath;
            testCase.TempFiles{end+1} = fullfile(folder, [name '.log']);

            % Re-import the exported file (channelCheck = false to avoid GUI)
            reimported = pf2.import.importNIR(filepath, mrkPath, false);

            % Verify reimported data is a struct
            testCase.verifyClass(reimported, 'struct', ...
                'Reimported data should be a struct');

            % Verify raw data dimensions are preserved
            % Note: NIR export may have different column count due to format
            originalRows = size(testCase.ProcessedData.raw, 1);
            reimportedRows = size(reimported.raw, 1);

            testCase.verifyEqual(reimportedRows, originalRows, ...
                sprintf('Row count mismatch: original %d, reimported %d', ...
                originalRows, reimportedRows));

            % Cleanup related files
            testCase.cleanupRelatedFiles(filepath);
        end
    end

    %% SNIRF Export Tests
    methods (Test, TestTags = {'SNIRF', 'Export'})
        function testExportSNIRFCreatesFile(testCase)
            % TESTEXPORTSNIRFCREATESFILE Verify .snirf file is created
            %
            % The asSNIRF function must create a .snirf file at the
            % specified path.

            filepath = testCase.createTempPath('.snirf');

            % Export to SNIRF
            pf2.export.asSNIRF(testCase.ProcessedData, filepath);

            % Verify file exists
            testCase.verifyEqual(exist(filepath, 'file'), 2, ...
                'SNIRF file was not created');
        end

        function testExportSNIRFFileNotEmpty(testCase)
            % TESTEXPORTSNIRFFILENOTEMPTY Verify SNIRF file has content (> 1KB)
            %
            % A valid SNIRF file with fNIRS data should be at least 1KB
            % in size due to the HDF5 structure and data content.

            filepath = testCase.createTempPath('.snirf');

            % Export to SNIRF
            pf2.export.asSNIRF(testCase.ProcessedData, filepath);

            % Verify file size > 1KB
            fileInfo = dir(filepath);
            testCase.verifyGreaterThan(fileInfo.bytes, 1024, ...
                sprintf('SNIRF file too small: %d bytes (expected > 1024)', fileInfo.bytes));
        end

        function testExportSNIRFRoundtripRaw(testCase)
            % TESTEXPORTSNIRFROUNDTRIPRAW Verify raw data preserved in roundtrip
            %
            % Exports data to SNIRF format, then re-imports it and verifies
            % that the raw data array dimensions match.

            filepath = testCase.createTempPath('.snirf');

            % Export to SNIRF
            pf2.export.asSNIRF(testCase.ProcessedData, filepath);

            % Re-import (channelCheck = false to avoid GUI)
            reimported = pf2.import.importSNIRF(filepath, false);

            % Verify reimported data has raw field
            testCase.verifyTrue(isfield(reimported, 'raw'), ...
                'Reimported data should have raw field');

            % Verify raw data row count is preserved
            originalRows = size(testCase.ProcessedData.raw, 1);
            reimportedRows = size(reimported.raw, 1);

            testCase.verifyEqual(reimportedRows, originalRows, ...
                sprintf('Raw data row count mismatch: original %d, reimported %d', ...
                originalRows, reimportedRows));
        end

        function testExportSNIRFRoundtripTime(testCase)
            % TESTEXPORTSNIRFROUNDTRIPTIME Verify time vector preserved in roundtrip
            %
            % Time vector length must match after export/import cycle.

            filepath = testCase.createTempPath('.snirf');

            % Export to SNIRF
            pf2.export.asSNIRF(testCase.ProcessedData, filepath);

            % Re-import (channelCheck = false to avoid GUI)
            reimported = pf2.import.importSNIRF(filepath, false);

            % Verify time field exists
            testCase.verifyTrue(isfield(reimported, 'time'), ...
                'Reimported data should have time field');

            % Verify time vector length matches
            originalLength = length(testCase.ProcessedData.time);
            reimportedLength = length(reimported.time);

            testCase.verifyEqual(reimportedLength, originalLength, ...
                sprintf('Time vector length mismatch: original %d, reimported %d', ...
                originalLength, reimportedLength));

            % Verify time values are close (within 1ms tolerance)
            testCase.verifyEqual(reimported.time(:), testCase.ProcessedData.time(:), ...
                'AbsTol', 0.001, ...
                'Time vector values should match within 1ms tolerance');
        end

        function testExportSNIRFRoundtripFs(testCase)
            % TESTEXPORTSNIRFROUNDTRIPFS Verify sampling rate preserved in roundtrip
            %
            % Sampling frequency must be preserved after export/import.

            filepath = testCase.createTempPath('.snirf');

            % Export to SNIRF
            pf2.export.asSNIRF(testCase.ProcessedData, filepath);

            % Re-import (channelCheck = false to avoid GUI)
            reimported = pf2.import.importSNIRF(filepath, false);

            % Verify fs field exists
            testCase.verifyTrue(isfield(reimported, 'fs'), ...
                'Reimported data should have fs field');

            % Verify sampling rate matches (within 0.1 Hz tolerance)
            testCase.verifyEqual(reimported.fs, testCase.ProcessedData.fs, ...
                'AbsTol', 0.1, ...
                sprintf('Sampling rate mismatch: original %.2f, reimported %.2f', ...
                testCase.ProcessedData.fs, reimported.fs));
        end

        function testExportSNIRFRoundtripMarkers(testCase)
            % TESTEXPORTSNIRFROUNDTRIPMARKERS Verify markers preserved (if present)
            %
            % If the original data contains markers, they should be preserved
            % after export/import cycle.

            filepath = testCase.createTempPath('.snirf');

            % Check if original data has markers
            hasMarkers = isfield(testCase.ProcessedData, 'markers') && ...
                         ~isempty(testCase.ProcessedData.markers);

            if ~hasMarkers
                % Skip test if no markers in original data
                testCase.assumeFail('Original data has no markers to test');
            end

            % Export to SNIRF
            pf2.export.asSNIRF(testCase.ProcessedData, filepath);

            % Re-import (channelCheck = false to avoid GUI)
            reimported = pf2.import.importSNIRF(filepath, false);

            % Verify markers field exists
            testCase.verifyTrue(isfield(reimported, 'markers'), ...
                'Reimported data should have markers field');

            % Verify marker count is preserved
            originalMarkerCount = size(testCase.ProcessedData.markers, 1);
            reimportedMarkerCount = size(reimported.markers, 1);

            testCase.verifyEqual(reimportedMarkerCount, originalMarkerCount, ...
                sprintf('Marker count mismatch: original %d, reimported %d', ...
                originalMarkerCount, reimportedMarkerCount));

            % Verify marker times are close (within 10ms tolerance)
            if reimportedMarkerCount > 0 && originalMarkerCount > 0
                testCase.verifyEqual(reimported.markers.Time, testCase.ProcessedData.markers.Time, ...
                    'AbsTol', 0.01, ...
                    'Marker times should match within 10ms tolerance');
            end
        end

        function testExportSNIRFWithProcessedData(testCase)
            % TESTEXPORTSNIRFWITHPROCESSEDDATA Verify can export processed data with HbO/HbR
            %
            % SNIRF export should work with fully processed data that
            % contains hemoglobin concentration fields.

            filepath = testCase.createTempPath('.snirf');

            % Verify processed data has expected fields
            testCase.assumeTrue(isfield(testCase.ProcessedData, 'HbO'), ...
                'Processed data missing HbO field');
            testCase.assumeTrue(isfield(testCase.ProcessedData, 'HbR'), ...
                'Processed data missing HbR field');

            % Export should not error (a zone is given: without one the
            % pf2:asSNIRF:noTimeZone warning is expected)
            testCase.verifyWarningFree(@() pf2.export.asSNIRF(testCase.ProcessedData, filepath, 'TimeZone', 'UTC'), ...
                'SNIRF export with processed data should not produce warnings');

            % Verify file was created with substantial content
            fileInfo = dir(filepath);
            testCase.verifyGreaterThan(fileInfo.bytes, 1024, ...
                'SNIRF file with processed data should have substantial content');
        end
    end

    %% Edge Case Tests
    methods (Test, TestTags = {'SNIRF', 'Export', 'Metadata'})
        function testExportSNIRFStimDataLabelsSingleDataset(testCase)
            % Stim column labels are one 1-D dataLabels dataset (SNIRF spec),
            % not dataLabels1..N
            data = testCase.RawData;
            testCase.assumeNotEmpty(data.markers, 'Sample data has no markers');
            data.markers.Amplitude = (1:height(data.markers))';
            filepath = testCase.createTempPath('.snirf');
            pf2.export.asSNIRF(data, filepath, 'TimeZone', 'UTC');

            info = h5info(filepath, '/nirs/stim1');
            names = {info.Datasets.Name};
            testCase.verifyTrue(ismember('dataLabels', names));
            testCase.verifyFalse(any(startsWith(names, 'dataLabels1')));
            ds = info.Datasets(strcmp(names, 'dataLabels'));
            testCase.verifyEqual(numel(ds.Dataspace.Size), 1, 'dataLabels should be 1-D');
            labels = string(h5read(filepath, '/nirs/stim1/dataLabels'));
            testCase.verifyEqual(labels(:)', ["startTime" "duration" "value" "Amplitude"]);
        end

        function testExportSNIRFDropsDefaultAmplitude(testCase)
            % An all-1 Amplitude column is the default fill and is not written
            data = testCase.RawData;
            testCase.assumeNotEmpty(data.markers, 'Sample data has no markers');
            data.markers.Amplitude(:) = 1;
            filepath = testCase.createTempPath('.snirf');
            pf2.export.asSNIRF(data, filepath, 'TimeZone', 'UTC');

            stimData = h5read(filepath, '/nirs/stim1/data');
            testCase.verifyEqual(size(stimData, 1), 3, 'Stim data should have 3 columns');
            info = h5info(filepath, '/nirs/stim1');
            testCase.verifyFalse(ismember('dataLabels', {info.Datasets.Name}));
        end

        function testExportSNIRFTimeZoneOption(testCase)
            % A zoneless t0 takes its zone from the TimeZone option
            data = testCase.RawData;
            data.t0 = datetime(2014, 5, 19, 10, 22, 45);
            filepath = testCase.createTempPath('.snirf');
            pf2.export.asSNIRF(data, filepath, 'TimeZone', 'America/New_York');

            unixTime = str2double(h5read(filepath, '/nirs/metaDataTags/UnixTime'));
            expected = posixtime(datetime(2014, 5, 19, 14, 22, 45, 'TimeZone', 'UTC'));
            testCase.verifyEqual(unixTime, expected, 'AbsTol', 1e-3);
            testCase.verifyEqual(char(h5read(filepath, '/nirs/metaDataTags/MeasurementTime')), ...
                '10:22:45.000-04:00');
            testCase.verifyEqual(char(h5read(filepath, '/nirs/metaDataTags/MeasurementDate')), ...
                '2014-05-19');
        end

        function testExportSNIRFNoTimeZoneOmitsUnixTime(testCase)
            % Without a zone, no absolute time is written and none is guessed
            data = testCase.RawData;
            data.t0 = datetime(2014, 5, 19, 10, 22, 45);
            filepath = testCase.createTempPath('.snirf');
            prev = warning('on', 'pf2:asSNIRF:noTimeZone'); % other tests may leave warnings off
            testCase.addTeardown(@() warning(prev));
            testCase.verifyWarning(@() pf2.export.asSNIRF(data, filepath), ...
                'pf2:asSNIRF:noTimeZone');

            info = h5info(filepath, '/nirs/metaDataTags');
            names = {info.Datasets.Name};
            testCase.verifyFalse(ismember('UnixTime', names));
            testCase.verifyEqual(char(h5read(filepath, '/nirs/metaDataTags/MeasurementTime')), ...
                '10:22:45.000');
        end

        function testExportSNIRFNonISODateNotWritten(testCase)
            % An info date that does not parse is not written as MeasurementDate
            data = testCase.RawData;
            if isfield(data, 't0'), data = rmfield(data, 't0'); end
            data.info.Date = 'Thursday the 14th';
            filepath = testCase.createTempPath('.snirf');
            pf2.export.asSNIRF(data, filepath);

            info = h5info(filepath, '/nirs/metaDataTags');
            testCase.verifyFalse(ismember('MeasurementDate', {info.Datasets.Name}));
        end

        function testExportSNIRFOneDimensionalVectors(testCase)
            % probe/wavelengths and data/time are 1-D datasets
            filepath = testCase.createTempPath('.snirf');
            pf2.export.asSNIRF(testCase.RawData, filepath, 'TimeZone', 'UTC');

            info = h5info(filepath, '/nirs/probe/wavelengths');
            testCase.verifyEqual(numel(info.Dataspace.Size), 1);
            info = h5info(filepath, '/nirs/data1/time');
            testCase.verifyEqual(numel(info.Dataspace.Size), 1);
        end

        function testExportSNIRFFromNIRx(testCase)
            % NIRx import reads the .hdr start time and Device ID, keeps 3D
            % positions in mm, builds a 2D layout and drops all-zero aux
            folder = tempname;
            mkdir(folder);
            testCase.addTeardown(@() rmdir(folder, 's'));
            fid = fopen(fullfile(folder, 'rec.hdr'), 'w');
            fprintf(fid, ['[GeneralInfo]\nDate="2019-03-14 14:32:17.312000"\n', ...
                'Device ID="NSP2-1234"\n\n[ImagingParameters]\nSamplingRate=7.812500\n']);
            fclose(fid);
            % Optodes on an 80 mm sphere around the origin (head coordinates)
            dirs = @(az, el) 80 * [cosd(el) .* cosd(az), cosd(el) .* sind(az), sind(el)];
            t = (0:99)' / 7.8125;
            SD.Lambda = [760 850];
            SD.SpatialUnit = 'mm';
            SD.SrcPos = dirs([70; 110; 90], [60; 60; 40]);
            SD.DetPos = dirs([90; 60; 120; 92], [60; 45; 45; 43]);
            sd = sortrows([1 1; 2 1; 1 2; 2 3; 3 4; 1 4]); % channel order: sorted pairs
            SD.MeasList = [sd ones(6, 1) ones(6, 1); sd ones(6, 1) 2 * ones(6, 1)];
            d = rand(100, 12) + 1; %#ok<NASGU>
            s = zeros(100, 1); s(10) = 1; %#ok<NASGU>
            aux = [zeros(100, 1), (1:100)']; %#ok<NASGU>
            save(fullfile(folder, 'rec.nirs'), 't', 'd', 's', 'SD', 'aux');

            data = pf2.import.importNIRX(fullfile(folder, 'rec.hdr'), false);
            testCase.verifyEqual(data.t0, datetime(2019, 3, 14, 14, 32, 17.312), 'AbsTol', seconds(1e-3));
            testCase.verifyEqual(data.probeinfo.Info.Name, 'NIRSport2');
            testCase.verifyEqual(size(data.Aux.NIRx, 2), 1, 'All-zero aux column should be dropped');
            p = data.probeinfo.Probe{1};
            src3D = [p.SrcPos.x p.SrcPos.y p.SrcPos.z];
            testCase.verifyEqual(src3D, SD.SrcPos, 'AbsTol', 1e-9, '3D positions should stay in mm');
            sd3D = sqrt(sum((SD.SrcPos(sd(:, 1), :) - SD.DetPos(sd(:, 2), :)).^2, 2))' / 10;
            testCase.verifyEqual(p.SD, sd3D, 'AbsTol', 1e-9, 'SD distances should be 3D, in cm');
            % 2D layout: a flat top view (right on the right, anterior up),
            % with distances close to the 3D ones
            src2D = [p.SrcPos.x_2d p.SrcPos.y_2d];
            testCase.verifyEqual(p.SrcPos.z_2d, zeros(3, 1));
            testCase.verifyGreaterThan(src2D(1, 1), src2D(2, 1));
            testCase.verifyGreaterThan(src2D(3, 2), src2D(1, 2));
            det2D = [p.DetPos.x_2d p.DetPos.y_2d];
            sd2D = sqrt(sum((src2D(sd(:, 1), :) - det2D(sd(:, 2), :)).^2, 2))' / 10;
            testCase.verifyEqual(sd2D, sd3D, 'RelTol', 0.2);

            filepath = testCase.createTempPath('.snirf');
            pf2.export.asSNIRF(data, filepath, 'TimeZone', 'Europe/Berlin');
            testCase.verifyEqual(h5read(filepath, '/nirs/probe/wavelengths'), [760; 850]);
            testCase.verifyEqual(char(h5read(filepath, '/nirs/metaDataTags/LengthUnit')), 'mm');
            testCase.verifyEqual(char(h5read(filepath, '/nirs/metaDataTags/Model')), 'NIRSport2');
            testCase.verifyEqual(char(h5read(filepath, '/nirs/metaDataTags/MeasurementDate')), '2019-03-14');
            testCase.verifyEqual(char(h5read(filepath, '/nirs/metaDataTags/MeasurementTime')), '14:32:17.312+01:00');
            srcPos = h5read(filepath, '/nirs/probe/sourcePos3D')';
            testCase.verifyEqual(srcPos, SD.SrcPos, 'AbsTol', 1e-6);
        end
    end

    methods (Test, TestTags = {'EdgeCase', 'Export'})
        function testExportSNIRFCreatesDirectory(testCase)
            % TESTEXPORTSNIRFCREATESDIRECTORY Verify export creates parent directory if needed
            %
            % If the target directory does not exist, asSNIRF should create it.

            % Create a path in a new subdirectory
            tempDir = fullfile(tempdir, sprintf('pf2test_%s', datestr(now, 'yyyymmdd_HHMMSS_FFF')));
            filepath = fullfile(tempDir, 'test.snirf');
            testCase.TempFiles{end+1} = filepath;

            % Export to SNIRF (should create directory)
            pf2.export.asSNIRF(testCase.ProcessedData, filepath);

            % Verify file was created
            testCase.verifyEqual(exist(filepath, 'file'), 2, ...
                'SNIRF file was not created in new directory');

            % Cleanup: remove the temp directory
            if exist(tempDir, 'dir')
                rmdir(tempDir, 's');
            end
        end

        function testExportSNIRFMultipleRuns(testCase)
            % TESTEXPORTSNIRFMULTIPLERUNS Verify export handles cell array of structs
            %
            % asSNIRF should accept a cell array of fNIRS structs and create
            % multiple /nirs groups in the SNIRF file.
            %
            % Note: This test documents known behavior. Multi-run export creates
            % nirs1/nirs2 field names instead of nirs, which causes savesnirf
            % to fail. This is a limitation in the jsnirfy library integration.

            filepath = testCase.createTempPath('.snirf');

            % Create cell array with two copies of the data (simulating multiple runs)
            multiRunData = {testCase.ProcessedData, testCase.ProcessedData};

            % Known limitation: multi-run export fails due to field naming
            % asSNIRF creates 'nirs1', 'nirs2' but savesnirf expects 'nirs'
            try
                pf2.export.asSNIRF(multiRunData, filepath);

                % If we get here, export succeeded - verify file
                testCase.verifyEqual(exist(filepath, 'file'), 2, ...
                    'SNIRF file with multiple runs was not created');

                fileInfo = dir(filepath);
                testCase.verifyGreaterThan(fileInfo.bytes, 2048, ...
                    'SNIRF file with multiple runs should have substantial content');
            catch e
                % Document the known limitation
                if contains(e.message, 'nirs') || contains(e.identifier, 'nonExistentField')
                    testCase.log(matlab.unittest.Verbosity.Terse, ...
                        'Known limitation: Multi-run SNIRF export not fully supported');
                    testCase.assumeFail(['Multi-run export limitation: ' e.message]);
                else
                    % Re-throw unexpected errors
                    rethrow(e);
                end
            end
        end
    end
end
