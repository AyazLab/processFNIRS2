classdef ImportNIRTest < matlab.unittest.TestCase
% IMPORTNIRTEST Unit tests for pf2.import.importNIR function
%
% Tests the NIR file import functionality to verify that imported data
% structures contain all required fields with correct dimensions and types.
%
% Test Data:
%   Uses sample data from sampledata/sampleNIR.nir and sampledata/sampleNIR.mrk
%
% Usage:
%   results = runtests('pf2_base.tests.unit.ImportNIRTest');
%   results = run(pf2_base.tests.unit.ImportNIRTest);
%
% See also: pf2.import.importNIR, matlab.unittest.TestCase

    properties (TestParameter)
        % Define any parameterized test inputs here if needed
    end

    properties (Access = private)
        Data         % Imported fNIRS data structure
        ProjectRoot  % Path to project root directory
    end

    methods (TestClassSetup)
        function setupOnce(testCase)
            % SETUPONCE Initialize test environment once before all tests
            %
            % Sets project root path and imports sample data that will be
            % shared across all test methods.

            % Get project root (three levels up from +pf2_base/+tests/+unit/)
            testCase.ProjectRoot = fileparts(fileparts(fileparts(fileparts(mfilename('fullpath')))));

            % Ensure we're in the project root for relative paths to work
            oldDir = cd(testCase.ProjectRoot);
            restoreDir = onCleanup(@() cd(oldDir));

            % Import sample data with markers, no channel check GUI
            nirFile = fullfile(testCase.ProjectRoot, 'sampledata', 'sampleNIR.nir');
            mrkFile = fullfile(testCase.ProjectRoot, 'sampledata', 'sampleNIR.mrk');

            testCase.assumeTrue(exist(nirFile, 'file') == 2, ...
                'Sample NIR file not found. Skipping tests.');
            testCase.assumeTrue(exist(mrkFile, 'file') == 2, ...
                'Sample MRK file not found. Skipping tests.');

            % Import data (channelCheck = false to avoid GUI)
            testCase.Data = pf2.import.importNIR(nirFile, mrkFile, false);
        end
    end

    methods (TestMethodSetup)
        function setupMethod(testCase)
            % SETUPMETHOD Verify data was loaded before each test
            testCase.assumeNotEmpty(testCase.Data, ...
                'Data import failed. Cannot run test.');
        end
    end

    methods (Test)
        function testImportReturnsStruct(testCase)
            % TESTIMPORTRETURNSSTRUCT Verify import returns a struct
            %
            % The importNIR function must return a MATLAB structure
            % containing the fNIRS data and metadata.

            testCase.verifyClass(testCase.Data, 'struct', ...
                'importNIR should return a struct');
        end

        function testRequiredFieldsPresent(testCase)
            % TESTREQUIREDFIELDSPRESENT Verify all required fields exist
            %
            % The fNIRS data structure must contain these fields:
            %   - raw: Raw light intensity data
            %   - time: Time vector
            %   - fs: Sampling frequency
            %   - fchMask: Channel validity mask
            %   - markers: Event markers
            %   - info: Metadata structure

            requiredFields = {'raw', 'time', 'fs', 'fchMask', 'markers', 'info'};

            for i = 1:length(requiredFields)
                fieldName = requiredFields{i};
                testCase.verifyTrue(isfield(testCase.Data, fieldName), ...
                    sprintf('Missing required field: %s', fieldName));
            end
        end

        function testRawDataDimensions(testCase)
            % TESTRAWDATADIMENSIONS Verify raw is T x C matrix (time x channels)
            %
            % Raw data must be a 2D numeric matrix where:
            %   - Rows represent time samples (T)
            %   - Columns represent channels (C)

            raw = testCase.Data.raw;

            % Verify raw is numeric
            testCase.verifyTrue(isnumeric(raw), ...
                'raw field should be numeric');

            % Verify raw is 2D matrix
            testCase.verifyEqual(ndims(raw), 2, ...
                'raw should be a 2D matrix');

            % Verify non-empty
            testCase.verifyGreaterThan(size(raw, 1), 0, ...
                'raw should have at least one time sample');
            testCase.verifyGreaterThan(size(raw, 2), 0, ...
                'raw should have at least one channel');
        end

        function testTimeDimensionConsistent(testCase)
            % TESTTIMEDIMENSIONCONSISTENT Verify size(raw, 1) == length(time)
            %
            % The number of time samples in raw data must match the
            % length of the time vector.

            numSamples = size(testCase.Data.raw, 1);
            timeLength = length(testCase.Data.time);

            testCase.verifyEqual(numSamples, timeLength, ...
                sprintf('Time dimension mismatch: raw has %d samples, time has %d elements', ...
                numSamples, timeLength));
        end

        function testSamplingRatePositive(testCase)
            % TESTSAMPLINGRATEPOSITIVE Verify fs > 0
            %
            % Sampling frequency must be a positive scalar value in Hz.

            fs = testCase.Data.fs;

            % Verify fs is numeric scalar
            testCase.verifyTrue(isscalar(fs) && isnumeric(fs), ...
                'fs should be a numeric scalar');

            % Verify fs is positive
            testCase.verifyGreaterThan(fs, 0, ...
                'Sampling frequency (fs) must be positive');
        end

        function testTimeIsMonotonic(testCase)
            % TESTTIMEISMONOTONIC Verify issorted(time)
            %
            % Time vector must be monotonically increasing to represent
            % a valid temporal sequence.

            time = testCase.Data.time;

            % Verify time is a vector
            testCase.verifyTrue(isvector(time), ...
                'time should be a vector');

            % Verify time is sorted (monotonically increasing)
            testCase.verifyTrue(issorted(time), ...
                'time vector should be monotonically increasing (sorted)');

            % Verify no duplicate time values
            testCase.verifyEqual(length(time), length(unique(time)), ...
                'time vector should not contain duplicate values');
        end

        function testInfoStructure(testCase)
            % TESTINFOSTRUCTURE Verify info has header, filename fields
            %
            % The info metadata structure must contain:
            %   - header: File header information
            %   - filename: Source file path

            info = testCase.Data.info;

            % Verify info is a struct
            testCase.verifyClass(info, 'struct', ...
                'info field should be a struct');

            % Verify header field exists
            testCase.verifyTrue(isfield(info, 'header'), ...
                'info should contain header field');

            % Verify filename field exists
            testCase.verifyTrue(isfield(info, 'filename'), ...
                'info should contain filename field');

            % Verify filename is non-empty string or char
            testCase.verifyTrue(ischar(info.filename) || isstring(info.filename), ...
                'info.filename should be a string or char array');
            testCase.verifyNotEmpty(info.filename, ...
                'info.filename should not be empty');
        end

        function testFchMaskDimensions(testCase)
            % TESTFCHMASKDIMENSIONS Verify fchMask is valid channel mask vector
            %
            % Channel mask must be a vector. Note that fchMask corresponds to
            % processed channels (after wavelength pairing), not raw channels.
            % For fNIR devices, raw data has ~3x more columns (multiple
            % wavelengths per channel) than the processed channel count.

            fchMask = testCase.Data.fchMask;

            % Verify fchMask is a vector
            testCase.verifyTrue(isvector(fchMask), ...
                'fchMask should be a vector');

            % Verify fchMask is non-empty
            testCase.verifyGreaterThan(length(fchMask), 0, ...
                'fchMask should have at least one element');

            % Verify fchMask contains only valid values (0 or 1, or logical)
            testCase.verifyTrue(all(fchMask == 0 | fchMask == 1), ...
                'fchMask should contain only 0 (bad) or 1 (good) values');
        end

        function testMarkersFormat(testCase)
            % TESTMARKERSFORMAT Verify markers has expected format
            %
            % Markers should be an M x N matrix (typically 3 or 4 columns):
            %   Column 1: Time (seconds)
            %   Column 2: Marker code/value
            %   Column 3: Duration
            %   Column 4: (optional) Additional marker data
            %
            % The exact number of columns may vary by file format.

            markers = testCase.Data.markers;

            % Verify markers is a table
            testCase.verifyTrue(istable(markers), ...
                'markers should be a table');

            % Convert to canonical numeric matrix for positional checks below
            markers = pf2_base.markersToArray(markers);

            % If markers exist, verify they have at least 3 columns
            if ~isempty(markers)
                testCase.verifyGreaterThanOrEqual(size(markers, 2), 3, ...
                    'markers should have at least 3 columns (time, code, duration)');

                % Verify marker times are finite values
                testCase.verifyTrue(all(isfinite(markers(:, 1))), ...
                    'marker times should be finite values');

                % Verify marker codes are finite values
                testCase.verifyTrue(all(isfinite(markers(:, 2))), ...
                    'marker codes should be finite values');
            end
        end

        function testTimeUnitsSeconds(testCase)
            % TESTTIMEUNITSSECONDS Verify time is in seconds (sanity check)
            %
            % Time vector should be in seconds. For typical fNIRS recordings,
            % duration is usually between a few seconds and several hours.

            time = testCase.Data.time;
            fs = testCase.Data.fs;

            % Calculate expected duration from sample count
            expectedDuration = (length(time) - 1) / fs;
            actualDuration = time(end) - time(1);

            % Allow 10% tolerance for timing discrepancies
            testCase.verifyEqual(actualDuration, expectedDuration, ...
                'RelTol', 0.1, ...
                'Time duration should be consistent with sample count and fs');
        end
    end

    methods (Test, TestTags = {'Header'})
        function testHeaderCurrentAndGainsSingleValue(testCase)
            % TESTHEADERCURRENTANDGAINSSINGLEVALUE Single-value header lines parse
            %
            % Older .nir files list one LED current and one gain value.

            h = testCase.Data.info.header;
            testCase.verifyEqual(h.current, 15);
            testCase.verifyEqual(h.gains, 5);
        end

        function testHeaderTwoValueLists(testCase)
            % TESTHEADERTWOVALUELISTS Two-value Current/Gains lines keep both values
            %
            % The short-separation sample lists a long and a short-separation
            % value on each line.

            nirFile = fullfile(testCase.ProjectRoot, 'sampledata', 'sampleNIR_ss.nir');
            data = pf2.import.importNIR(nirFile, '', false);
            testCase.verifyEqual(data.info.header.current, [30 1]);
            testCase.verifyEqual(data.info.header.gains, [5 1]);
        end

        function testHeaderListsRoundTrip(testCase)
            % TESTHEADERLISTSROUNDTRIP Full Current/Gains lists survive export and import
            %
            % COBI Studio Modern can write four long-separation LED currents (one
            % per quadrant) and two short-separation ones, and one gain per
            % optode, as comma-separated lists; all values must be kept.

            data = testCase.Data;
            data.info.header.current = [5 5 10 20 1 1];
            data.info.header.gains = [1 3 2 1 2 1 3 1 3 3 20 20 20 20 20 20 1 2];
            outFile = [tempname '.nir'];
            cleanup = onCleanup(@() deleteIfPresent(outFile));
            pf2.export.asNIR(data, outFile);
            back = pf2.import.importNIR(outFile, '', false);
            testCase.verifyEqual(back.info.header.current, data.info.header.current);
            testCase.verifyEqual(back.info.header.gains, data.info.header.gains);
        end
    end

    methods (Test, TestTags = {'Robustness'})
        function testRawDataNoNaN(testCase)
            % TESTRAWDATANONAN Verify raw data contains no NaN values
            %
            % Imported raw data should not contain NaN values.
            % NaN values may be introduced later during processing.

            raw = testCase.Data.raw;

            testCase.verifyFalse(any(isnan(raw(:))), ...
                'Raw data should not contain NaN values upon import');
        end

        function testRawDataNoInf(testCase)
            % TESTRAWDATANOINF Verify raw data contains no Inf values
            %
            % Imported raw data should not contain infinite values.

            raw = testCase.Data.raw;

            testCase.verifyFalse(any(isinf(raw(:))), ...
                'Raw data should not contain Inf values');
        end
    end
end


function deleteIfPresent(f)
% DELETEIFPRESENT Remove a temporary file if it exists
if exist(f, 'file') == 2
    delete(f);
end
end
