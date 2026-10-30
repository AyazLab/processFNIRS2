classdef FullPipelineTest < matlab.unittest.TestCase
% FULLPIPELINETEST Integration tests for the complete processFNIRS2 pipeline
%
% Tests the full processing workflow from raw data import through
% hemoglobin concentration output. Verifies that the pipeline produces
% valid output structures with expected fields, preserves critical
% metadata, and works with different device configurations and
% processing methods.
%
% Test Methods:
%   testFullPipelineRuns           - Verifies processFNIRS2 completes without error
%   testFullPipelineOutputFields   - Checks all required output fields present
%   testFullPipelinePreservesTime  - Confirms time dimension preserved
%   testFullPipelinePreservesMarkers - Confirms markers preserved
%   testFullPipelinePreservesInfo  - Confirms info struct preserved
%   testDifferentDevices           - Tests with fNIR2000 and Hitachi data
%   testDifferentMethods           - Tests with different raw/oxy methods
%
% Example:
%   % Run all tests in this class
%   results = runtests('pf2_base.tests.integration.FullPipelineTest');
%
%   % Run a specific test
%   results = runtests('pf2_base.tests.integration.FullPipelineTest/testFullPipelineRuns');
%
% See also: processFNIRS2, pf2.import.sampleData, matlab.unittest.TestCase

    properties (TestParameter)
        % Method combinations, built with the Pipeline API so the test does
        % not depend on the user's stored method library. Each value lists
        % pipeline steps as {funcName, paramStruct} pairs; {} means 'None'.
        rawMethod = struct( ...
            'None', {{}}, ...
            'OD_lpf', {{{'pf2_Intensity2OD', struct()}, {'pf2_lpf', struct('freq_cut', 0.1)}}}, ...
            'OD_TDDR', {{{'pf2_Intensity2OD', struct()}, {'pf2_MotionCorrectTDDR', struct()}}});
        oxyMethod = struct( ...
            'None', {{}}, ...
            'lpf_CAR', {{{'pf2_lpf', struct('freq_cut', 0.1)}, {'pf2_CAR', struct()}}});
    end

    properties
        % Cached sample data to avoid repeated loading
        fNIR2000Data
        HitachiData
    end

    methods (TestClassSetup)
        function loadSampleData(testCase)
            % Load sample data once for all tests in this class
            % This improves test performance by avoiding repeated file I/O

            % Load fNIR2000 sample data
            try
                testCase.fNIR2000Data = pf2.import.sampleData.fNIR2000();
            catch ME
                testCase.fNIR2000Data = [];
                warning('FullPipelineTest:DataLoadFailed', ...
                    'Failed to load fNIR2000 sample data: %s', ME.message);
            end

            % Load Hitachi sample data
            try
                testCase.HitachiData = pf2.import.sampleData.Hitachi_ETG4000_3x5();
            catch ME
                testCase.HitachiData = [];
                warning('FullPipelineTest:DataLoadFailed', ...
                    'Failed to load Hitachi sample data: %s', ME.message);
            end
        end
    end

    methods (TestMethodSetup)
        function resetProcessingState(testCase)
            % Reset global processing state before each test
            % Ensures tests are independent and reproducible

            % Clear global variables used by processFNIRS2
            clearvars -global PF2 setF outputData;
        end
    end

    methods (Test)
        function testFullPipelineRuns(testCase)
            % Test that processFNIRS2 completes without error
            %
            % Verifies that the main processing function can be called
            % with sample data and returns without throwing an exception.

            testCase.assumeNotEmpty(testCase.fNIR2000Data, ...
                'fNIR2000 sample data not available');

            % Process data - should complete without error
            processed = processFNIRS2(testCase.fNIR2000Data);

            % Verify output is not empty
            testCase.verifyNotEmpty(processed, ...
                'processFNIRS2 should return non-empty output');

            % Verify output is a struct
            testCase.verifyClass(processed, 'struct', ...
                'processFNIRS2 should return a struct');
        end

        function testFullPipelineOutputFields(testCase)
            % Test that output contains all required hemoglobin fields
            %
            % According to the data structure documentation, processed
            % output should contain: HbO, HbR, HbTotal, HbDiff, CBSI,
            % channels, and units fields.

            testCase.assumeNotEmpty(testCase.fNIR2000Data, ...
                'fNIR2000 sample data not available');

            processed = processFNIRS2(testCase.fNIR2000Data);

            % Check for required biomarker fields
            requiredFields = {'HbO', 'HbR', 'HbTotal', 'HbDiff', 'CBSI', ...
                             'channels', 'units'};

            for i = 1:length(requiredFields)
                fieldName = requiredFields{i};
                testCase.verifyTrue(isfield(processed, fieldName), ...
                    sprintf('Output should contain field: %s', fieldName));
            end

            % Verify biomarker data is numeric and non-empty
            biomarkers = {'HbO', 'HbR', 'HbTotal', 'HbDiff', 'CBSI'};
            for i = 1:length(biomarkers)
                fieldName = biomarkers{i};
                testCase.verifyClass(processed.(fieldName), 'double', ...
                    sprintf('%s should be double', fieldName));
                testCase.verifyGreaterThan(numel(processed.(fieldName)), 0, ...
                    sprintf('%s should not be empty', fieldName));
            end

            % Verify channels is numeric
            testCase.verifyClass(processed.channels, 'double', ...
                'channels should be numeric');

            % Verify units is char or string
            testCase.verifyTrue(ischar(processed.units) || isstring(processed.units), ...
                'units should be char or string');
        end

        function testFullPipelinePreservesTime(testCase)
            % Test that time dimension is preserved through processing
            %
            % The number of time points in the output hemoglobin data
            % should match the number of time points in the time vector.

            testCase.assumeNotEmpty(testCase.fNIR2000Data, ...
                'fNIR2000 sample data not available');

            inputData = testCase.fNIR2000Data;
            processed = processFNIRS2(inputData);

            % Verify time field exists
            testCase.verifyTrue(isfield(processed, 'time'), ...
                'Output should contain time field');

            % Verify time vector length matches HbO first dimension
            numTimePoints = length(processed.time);
            [hboTimePoints, ~] = size(processed.HbO);

            testCase.verifyEqual(hboTimePoints, numTimePoints, ...
                'HbO time dimension should match time vector length');

            % Verify sampling frequency is preserved
            testCase.verifyTrue(isfield(processed, 'fs'), ...
                'Output should contain fs (sampling frequency)');
            testCase.verifyEqual(processed.fs, inputData.fs, ...
                'Sampling frequency should be preserved');
        end

        function testFullPipelinePreservesMarkers(testCase)
            % Test that event markers are preserved through processing
            %
            % Markers contain important experimental timing information
            % and should be passed through unchanged.

            testCase.assumeNotEmpty(testCase.fNIR2000Data, ...
                'fNIR2000 sample data not available');

            inputData = testCase.fNIR2000Data;

            % Only test if input has markers
            testCase.assumeTrue(isfield(inputData, 'markers') && ...
                ~isempty(inputData.markers), ...
                'Input data has no markers to test');

            processed = processFNIRS2(inputData);

            % Verify markers field exists
            testCase.verifyTrue(isfield(processed, 'markers'), ...
                'Output should contain markers field');

            % Verify markers content is preserved: same row count AND the
            % canonical table schema, so a dropped Code/Amplitude column is
            % caught (not just a count match).
            testCase.verifyEqual(size(processed.markers, 1), size(inputData.markers, 1), ...
                'Marker count should be preserved');
            if istable(processed.markers) && ~isempty(processed.markers)
                testCase.verifyEqual(processed.markers.Properties.VariableNames(1:4), ...
                    {'Time','Code','Duration','Amplitude'}, ...
                    'Processed markers must retain the canonical variables');
                if istable(inputData.markers)
                    testCase.verifyEqual(processed.markers.Code, inputData.markers.Code, ...
                        'Marker codes should be preserved through processing');
                end
            end
        end

        function testFullPipelinePreservesInfo(testCase)
            % Test that info struct is preserved through processing
            %
            % The info struct contains important metadata like subject ID,
            % probe name, and header information that should be preserved.

            testCase.assumeNotEmpty(testCase.fNIR2000Data, ...
                'fNIR2000 sample data not available');

            inputData = testCase.fNIR2000Data;

            % Only test if input has info
            testCase.assumeTrue(isfield(inputData, 'info'), ...
                'Input data has no info struct to test');

            processed = processFNIRS2(inputData);

            % Verify info field exists
            testCase.verifyTrue(isfield(processed, 'info'), ...
                'Output should contain info field');

            % Verify info is a struct
            testCase.verifyClass(processed.info, 'struct', ...
                'info should be a struct');

            % Check that key info fields are preserved if they exist
            keyInfoFields = {'SubjectID', 'probename', 'header'};
            for i = 1:length(keyInfoFields)
                fieldName = keyInfoFields{i};
                if isfield(inputData.info, fieldName)
                    testCase.verifyTrue(isfield(processed.info, fieldName), ...
                        sprintf('info.%s should be preserved', fieldName));
                end
            end
        end

        function testDifferentDevices(testCase)
            % Test pipeline with different device configurations
            %
            % Verifies that processFNIRS2 works correctly with data
            % from both fNIR Devices (fNIR2000) and Hitachi (ETG-4000)
            % systems.

            % Test with fNIR2000 data
            if ~isempty(testCase.fNIR2000Data)
                processed_fnir = processFNIRS2(testCase.fNIR2000Data);

                testCase.verifyTrue(isfield(processed_fnir, 'HbO'), ...
                    'fNIR2000 processed data should have HbO field');
                testCase.verifyGreaterThan(numel(processed_fnir.HbO), 0, ...
                    'fNIR2000 HbO should not be empty');
            else
                testCase.log(matlab.unittest.Verbosity.Detailed, ...
                    'Skipping fNIR2000 device test - data not available');
            end

            % Test with Hitachi data
            if ~isempty(testCase.HitachiData)
                processed_hitachi = processFNIRS2(testCase.HitachiData);

                testCase.verifyTrue(isfield(processed_hitachi, 'HbO'), ...
                    'Hitachi processed data should have HbO field');
                testCase.verifyGreaterThan(numel(processed_hitachi.HbO), 0, ...
                    'Hitachi HbO should not be empty');
            else
                testCase.log(matlab.unittest.Verbosity.Detailed, ...
                    'Skipping Hitachi device test - data not available');
            end

            % Ensure at least one device was tested
            testCase.assumeTrue(~isempty(testCase.fNIR2000Data) || ...
                               ~isempty(testCase.HitachiData), ...
                'At least one device sample data should be available');
        end

        function testDifferentMethods(testCase, rawMethod, oxyMethod)
            % Test pipeline with different processing method combinations
            %
            % This parameterized test verifies that different combinations
            % of raw and oxy processing methods work correctly.

            testCase.assumeNotEmpty(testCase.fNIR2000Data, ...
                'fNIR2000 sample data not available');

            % Run through an isolated ProcessingContext so the user's global
            % method selection is neither required nor changed.
            ctx = pf2.ProcessingContext();
            if ~isempty(rawMethod)
                ctx.rawMethod = buildMethod(pf2_base.RawPipeline('TestRaw'), rawMethod);
            end
            if ~isempty(oxyMethod)
                ctx.oxyMethod = buildMethod(pf2_base.OxyPipeline('TestOxy'), oxyMethod);
            end
            processed = ctx.process(testCase.fNIR2000Data);
            label = sprintf('raw=%s, oxy=%s', ctx.rawMethodName, ctx.oxyMethodName);

            % Verify output has required fields
            testCase.verifyTrue(isfield(processed, 'HbO'), ...
                sprintf('Output with %s should have HbO', label));

            testCase.verifyTrue(isfield(processed, 'HbR'), ...
                sprintf('Output with %s should have HbR', label));

            % Verify data is valid (not all NaN)
            testCase.verifyFalse(all(isnan(processed.HbO(:))), ...
                sprintf('HbO with %s should not be all NaN', label));
        end
    end

    methods (Test, TestTags = {'Extended'})
        function testOutputDataDimensions(testCase)
            % Extended test: Verify output data dimensions are consistent
            %
            % All biomarker arrays should have the same dimensions,
            % matching [TimePoints x Channels].

            testCase.assumeNotEmpty(testCase.fNIR2000Data, ...
                'fNIR2000 sample data not available');

            processed = processFNIRS2(testCase.fNIR2000Data);

            % Get dimensions from HbO as reference
            [T, C] = size(processed.HbO);

            % Verify all biomarkers have same dimensions
            biomarkers = {'HbO', 'HbR', 'HbTotal', 'HbDiff', 'CBSI'};
            for i = 1:length(biomarkers)
                [Ti, Ci] = size(processed.(biomarkers{i}));
                testCase.verifyEqual([Ti, Ci], [T, C], ...
                    sprintf('%s dimensions should match HbO [%d x %d]', ...
                    biomarkers{i}, T, C));
            end

            % Verify channels vector length matches second dimension
            testCase.verifyEqual(length(processed.channels), C, ...
                'channels vector length should match data columns');

            % Verify time vector length matches first dimension
            testCase.verifyEqual(length(processed.time), T, ...
                'time vector length should match data rows');
        end

        function testDPFfactorPresent(testCase)
            % Extended test: Verify DPF factor is recorded in output
            %
            % The differential pathlength factor used in Beer-Lambert
            % conversion should be stored in the output structure.

            testCase.assumeNotEmpty(testCase.fNIR2000Data, ...
                'fNIR2000 sample data not available');

            processed = processFNIRS2(testCase.fNIR2000Data);

            testCase.verifyTrue(isfield(processed, 'DPF_factor'), ...
                'Output should contain DPF_factor field');

            testCase.verifyGreaterThan(processed.DPF_factor, 0, ...
                'DPF_factor should be positive');
        end

        function testRawDataPreserved(testCase)
            % Extended test: Verify raw data is preserved in output
            %
            % The original raw light intensity data should be preserved
            % in the output structure for reference and reprocessing.

            testCase.assumeNotEmpty(testCase.fNIR2000Data, ...
                'fNIR2000 sample data not available');

            inputData = testCase.fNIR2000Data;
            processed = processFNIRS2(inputData);

            testCase.verifyTrue(isfield(processed, 'raw'), ...
                'Output should contain raw field');

            % Raw data dimensions should be preserved
            testCase.verifyEqual(size(processed.raw, 1), size(inputData.raw, 1), ...
                'Raw data time dimension should be preserved');
        end
    end
end

function method = buildMethod(pipe, steps)
% BUILDMETHOD Add {funcName, params} steps to a pipeline and return its method.
for k = 1:numel(steps)
    if isempty(fieldnames(steps{k}{2}))
        pipe = pipe.add(steps{k}{1});
    else
        pipe = pipe.add(steps{k}{1}, steps{k}{2});
    end
end
method = pipe.toMethod();
end
