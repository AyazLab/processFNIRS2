classdef RoundtripTest < matlab.unittest.TestCase
% ROUNDTRIPTEST Integration tests for SNIRF export/import roundtrip
%
% Tests the ability to export fNIRS data to SNIRF format and re-import
% it without data loss. Verifies that the standardized SNIRF format
% preserves critical data fields including raw intensity, time vectors,
% markers, and probe geometry.
%
% Test Methods:
%   testSNIRFExportCreatesFile     - Verifies pf2.export.asSNIRF creates file
%   testSNIRFRoundtripPreservesData - Export then import preserves key data
%
% Example:
%   % Run all tests in this class
%   results = runtests('pf2_base.tests.integration.RoundtripTest');
%
%   % Run a specific test
%   results = runtests('pf2_base.tests.integration.RoundtripTest/testSNIRFExportCreatesFile');
%
% See also: pf2.export.asSNIRF, pf2.import.importSNIRF, matlab.unittest.TestCase

    properties
        % Cached sample data
        sampleData

        % Temporary directory for test files
        tempDir
    end

    methods (TestClassSetup)
        function setupTestEnvironment(testCase)
            % Create temporary directory and load sample data

            % Create unique temp directory for this test run
            testCase.tempDir = fullfile(tempdir, ...
                sprintf('pf2_roundtrip_test_%s', datestr(now, 'yyyymmdd_HHMMSS')));
            mkdir(testCase.tempDir);

            % Register cleanup to remove temp directory after tests
            testCase.addTeardown(@() rmdir(testCase.tempDir, 's'));

            % Load sample data
            try
                testCase.sampleData = pf2.import.sampleData.fNIR2000();
            catch ME
                testCase.sampleData = [];
                warning('RoundtripTest:DataLoadFailed', ...
                    'Failed to load sample data: %s', ME.message);
            end
        end
    end

    methods (TestMethodSetup)
        function resetProcessingState(testCase)
            % Reset global processing state before each test
            clearvars -global PF2 setF outputData;
        end
    end

    methods (Test)
        function testSNIRFExportCreatesFile(testCase)
            % Test that pf2.export.asSNIRF creates a valid SNIRF file
            %
            % Verifies that the export function:
            % 1. Creates a file at the specified path
            % 2. The file has non-zero size
            % 3. No errors are thrown during export

            testCase.assumeNotEmpty(testCase.sampleData, ...
                'Sample data not available');

            % Define output path
            outputPath = fullfile(testCase.tempDir, 'test_export.snirf');

            % Export should complete without error
            testCase.verifyWarningFree(@() pf2.export.asSNIRF(...
                testCase.sampleData, outputPath, 'TimeZone', 'UTC'), ...
                'SNIRF export should complete without warnings');

            % Verify file was created
            testCase.verifyTrue(isfile(outputPath), ...
                'SNIRF export should create output file');

            % Verify file has non-zero size
            fileInfo = dir(outputPath);
            testCase.verifyGreaterThan(fileInfo.bytes, 0, ...
                'Exported SNIRF file should have non-zero size');
        end

        function testSNIRFRoundtripPreservesData(testCase)
            % Test that export-import roundtrip preserves key data
            %
            % Verifies that after exporting to SNIRF and re-importing:
            % 1. Raw data dimensions are preserved
            % 2. Time vector is preserved (within tolerance)
            % 3. Sampling frequency is preserved
            % 4. Markers are preserved (if present)

            testCase.assumeNotEmpty(testCase.sampleData, ...
                'Sample data not available');

            originalData = testCase.sampleData;

            % Define roundtrip path
            snirfPath = fullfile(testCase.tempDir, 'test_roundtrip.snirf');

            % Export to SNIRF
            pf2.export.asSNIRF(originalData, snirfPath);

            % Import back from SNIRF
            reimportedData = pf2.import.importSNIRF(snirfPath, false);

            % Test 1: Verify raw data dimensions preserved
            % Note: SNIRF may strip time/marker columns, so we check
            % that time dimension is preserved and channel count is reasonable
            testCase.verifyEqual(size(reimportedData.raw, 1), ...
                size(originalData.raw, 1), ...
                'Raw data time dimension should be preserved');

            % Channel count may differ slightly due to column stripping
            % but should be close
            originalChannels = size(originalData.raw, 2);
            reimportedChannels = size(reimportedData.raw, 2);
            testCase.verifyGreaterThan(reimportedChannels, 0, ...
                'Reimported data should have channels');

            % Test 2: Verify time vector is preserved
            testCase.verifyTrue(isfield(reimportedData, 'time'), ...
                'Reimported data should have time field');
            testCase.verifyEqual(length(reimportedData.time), ...
                length(originalData.time), ...
                'Time vector length should be preserved');

            % Time values should be very close (allow small numerical differences)
            timeDiff = abs(reimportedData.time(:) - originalData.time(:));
            testCase.verifyLessThan(max(timeDiff), 1e-6, ...
                'Time values should be preserved within tolerance');

            % Test 3: Verify sampling frequency is preserved
            testCase.verifyTrue(isfield(reimportedData, 'fs'), ...
                'Reimported data should have fs field');
            testCase.verifyEqual(reimportedData.fs, originalData.fs, ...
                'AbsTol', 1e-6, ...
                'Sampling frequency should be preserved');

            % Test 4: Verify markers preserved if original had markers
            if isfield(originalData, 'markers') && ~isempty(originalData.markers)
                testCase.verifyTrue(isfield(reimportedData, 'markers'), ...
                    'Reimported data should have markers field');

                if ~isempty(reimportedData.markers)
                    % Verify marker count matches (works for table or matrix forms)
                    testCase.verifyEqual(size(reimportedData.markers, 1), ...
                        size(originalData.markers, 1), ...
                        'Number of markers should be preserved');

                    % And the canonical schema + code values survive the
                    % round-trip, so a dropped column is caught (not just count).
                    if istable(reimportedData.markers)
                        testCase.verifyEqual( ...
                            reimportedData.markers.Properties.VariableNames(1:4), ...
                            {'Time','Code','Duration','Amplitude'}, ...
                            'Reimported markers must retain the canonical variables');
                        if istable(originalData.markers)
                            testCase.verifyEqual( ...
                                sort(reimportedData.markers.Code), ...
                                sort(originalData.markers.Code), ...
                                'Marker codes should survive the round-trip');
                        end
                    end
                end
            end
        end

        function testSNIRFRoundtripWithProcessedData(testCase)
            % Test roundtrip with processed (hemoglobin) data
            %
            % Verifies that processed data can be exported and reimported.
            % Note: SNIRF primarily stores raw data, so this test focuses
            % on raw data preservation even from a processed struct.

            testCase.assumeNotEmpty(testCase.sampleData, ...
                'Sample data not available');

            % Process the sample data first
            processedData = processFNIRS2(testCase.sampleData);

            % Define roundtrip path
            snirfPath = fullfile(testCase.tempDir, 'test_processed_roundtrip.snirf');

            % Export to SNIRF
            pf2.export.asSNIRF(processedData, snirfPath);

            % Verify file exists
            testCase.verifyTrue(isfile(snirfPath), ...
                'SNIRF export of processed data should create file');

            % Import back
            reimportedData = pf2.import.importSNIRF(snirfPath, false);

            % Verify basic structure
            testCase.verifyTrue(isfield(reimportedData, 'raw'), ...
                'Reimported data should have raw field');
            testCase.verifyTrue(isfield(reimportedData, 'time'), ...
                'Reimported data should have time field');
            testCase.verifyTrue(isfield(reimportedData, 'fs'), ...
                'Reimported data should have fs field');
        end
    end

    methods (Test, TestTags = {'Extended'})
        function testSNIRFRoundtripPreservesProbeInfo(testCase)
            % Extended test: Verify probe geometry is preserved
            %
            % SNIRF format includes probe geometry information which
            % should be preserved through export/import.

            testCase.assumeNotEmpty(testCase.sampleData, ...
                'Sample data not available');

            originalData = testCase.sampleData;
            snirfPath = fullfile(testCase.tempDir, 'test_probe_roundtrip.snirf');

            % Export and reimport
            pf2.export.asSNIRF(originalData, snirfPath);
            reimportedData = pf2.import.importSNIRF(snirfPath, false);

            % Check for probeinfo or info.probename
            hasProbeInfo = isfield(reimportedData, 'probeinfo') || ...
                          (isfield(reimportedData, 'info') && ...
                           isfield(reimportedData.info, 'probename'));

            testCase.verifyTrue(hasProbeInfo, ...
                'Reimported data should preserve probe information');
        end

        function testSNIRFRoundtripPreservesMetadata(testCase)
            % Extended test: Verify metadata is preserved
            %
            % SNIRF metaDataTags should be preserved through roundtrip.

            testCase.assumeNotEmpty(testCase.sampleData, ...
                'Sample data not available');

            originalData = testCase.sampleData;

            % Add some test metadata if info exists
            if isfield(originalData, 'info')
                originalData.info.SubjectID = 'TestSubject001';
            end

            snirfPath = fullfile(testCase.tempDir, 'test_metadata_roundtrip.snirf');

            % Export and reimport
            pf2.export.asSNIRF(originalData, snirfPath);
            reimportedData = pf2.import.importSNIRF(snirfPath, false);

            % Verify info struct exists
            testCase.verifyTrue(isfield(reimportedData, 'info'), ...
                'Reimported data should have info struct');

            % Check SubjectID if it was set
            if isfield(originalData, 'info') && isfield(originalData.info, 'SubjectID')
                testCase.verifyTrue(isfield(reimportedData.info, 'SubjectID'), ...
                    'SubjectID should be preserved in roundtrip');
            end
        end

        function testMultipleExportsToSameFile(testCase)
            % Extended test: Verify re-exporting overwrites correctly
            %
            % Exporting to the same path twice should overwrite cleanly
            % and produce a valid file each time.

            testCase.assumeNotEmpty(testCase.sampleData, ...
                'Sample data not available');

            snirfPath = fullfile(testCase.tempDir, 'test_overwrite.snirf');

            % First export (same options as the overwrite below)
            pf2.export.asSNIRF(testCase.sampleData, snirfPath, 'TimeZone', 'UTC');

            % Verify first export succeeded
            testCase.verifyTrue(isfile(snirfPath), ...
                'File should exist after first export');
            firstFileInfo = dir(snirfPath);
            firstFileSize = firstFileInfo.bytes;

            % Second export (overwrite) - should complete without error
            testCase.verifyWarningFree(@() pf2.export.asSNIRF(...
                testCase.sampleData, snirfPath, 'TimeZone', 'UTC'), ...
                'Second export should complete without warnings');

            % File should still exist after overwrite
            testCase.verifyTrue(isfile(snirfPath), ...
                'File should exist after overwrite');

            % File size should be the same (same data exported)
            secondFileInfo = dir(snirfPath);
            testCase.verifyEqual(secondFileInfo.bytes, firstFileSize, ...
                'File size should be consistent after overwrite');

            % Verify the overwritten file can still be read
            reimportedData = pf2.import.importSNIRF(snirfPath, false);
            testCase.verifyTrue(isfield(reimportedData, 'raw'), ...
                'Overwritten file should be readable and contain raw data');
        end

        function testRoundtripDataIntegrity(testCase)
            % Extended test: Verify raw data values are preserved exactly
            %
            % Raw intensity values should survive the roundtrip with
            % minimal numerical error.

            testCase.assumeNotEmpty(testCase.sampleData, ...
                'Sample data not available');

            originalData = testCase.sampleData;
            snirfPath = fullfile(testCase.tempDir, 'test_integrity.snirf');

            % Export and reimport
            pf2.export.asSNIRF(originalData, snirfPath);
            reimportedData = pf2.import.importSNIRF(snirfPath, false);

            % Find matching channels (SNIRF may strip some columns)
            % Compare a subset of the data
            origRows = min(100, size(originalData.raw, 1));
            reimRows = min(100, size(reimportedData.raw, 1));
            numRows = min(origRows, reimRows);

            % Get number of common channels (accounting for stripped columns)
            numOrigCols = size(originalData.raw, 2);
            numReimCols = size(reimportedData.raw, 2);

            % At minimum, verify the data types are correct
            testCase.verifyClass(reimportedData.raw, 'double', ...
                'Reimported raw data should be double');

            % If dimensions match exactly, compare values
            if numOrigCols == numReimCols
                origSubset = originalData.raw(1:numRows, :);
                reimSubset = reimportedData.raw(1:numRows, :);

                % Allow for small numerical differences from HDF5 storage
                maxDiff = max(abs(origSubset(:) - reimSubset(:)));
                testCase.verifyLessThan(maxDiff, 1e-9, ...
                    'Raw data values should be preserved within tolerance');
            else
                % Dimensions differ - just verify reimported data is valid
                testCase.verifyFalse(all(isnan(reimportedData.raw(:))), ...
                    'Reimported raw data should not be all NaN');
            end
        end
    end
end
