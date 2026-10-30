classdef NirCounterTimebaseTest < matlab.unittest.TestCase
% NIRCOUNTERTIMEBASETEST Tests for the COBI .nir sample-counter time base
%
% Synthetic recordings with a known true sample time exercise
% pf2_base.nirCounterTimebase: the fitted counter tick, the latency-floor
% anchor, counter resets, PC clock restarts (carried by the counter), PC
% clock steps, delivery backlogs, counter pauses at dropouts, and the
% sampling rate. An end-to-end test writes a 2000M .nir file and imports
% it with pf2.import.importNIR.
%
% Usage:
%   results = runtests('pf2_base.tests.unit.NirCounterTimebaseTest');
%
% See also: pf2_base.nirCounterTimebase, pf2.import.importNIR

    methods (Test, TestTags = {'Import', 'NIR', 'Timebase'})
        function test2000MRecovery(testCase)
            % 2000M: 33/32768 s tick, 5 Hz, stamping jitter, stalls,
            % dropped samples, two counter resets with 2 s gaps and a PC
            % clock restart while the counter runs on
            rec = testCase.synthRun('Tick', 33/32768, 'Fs', 5, 'Duration', 3600, ...
                'ResetsAt', [1200 2400], 'RestartAt', 3000, 'StallsAt', [100 300 1800 3100], ...
                'DropAt', 600);
            [t, tb] = pf2_base.nirCounterTimebase(rec.pc, rec.counter, 'Model', 'Model 2000M Imager');

            testCase.verifyLessThan(max(abs(t - rec.truth)), 0.01, ...
                'Event-time error should be 10 ms or less');
            testCase.verifyEqual(tb.fs, 5, 'AbsTol', 1e-3);
            testCase.verifyEqual(tb.pooledTick, 33/32768, 'RelTol', 1e-5);
            testCase.verifyEqual(tb.counterResets, 2);
            testCase.verifyEqual(tb.pcRestarts, 1);
            kinds = tb.gaps.Kind;
            testCase.verifyEqual(sum(strcmp(kinds, 'counter reset')), 2);
            testCase.verifyEqual(sum(strcmp(kinds, 'dropped samples')), 1);
            resetGaps = tb.gaps.Length(strcmp(kinds, 'counter reset'));
            testCase.verifyEqual(resetGaps, [2; 2], 'AbsTol', 0.01, ...
                'Reset gaps should keep their measured length');
            testCase.verifyEqual(sum(tb.pieces.DroppedSamples), 5);
            testCase.verifyTrue(all(diff(t) > 0));
        end

        function testOldMethodDrift2000M(testCase)
            % The previous 1 kHz counter assumption runs 0.7% fast on a
            % 2000M: about 25 s over an hour, and fs 5.025 Hz
            rec = testCase.synthRun('Tick', 33/32768, 'Fs', 5, 'Duration', 3600);
            old = rec.pc(1) + (rec.counter - rec.counter(1)) / 1000;
            testCase.verifyGreaterThan(abs(old(end) - rec.truth(end)), 20);
            [t, tb] = pf2_base.nirCounterTimebase(rec.pc, rec.counter, 'Model', '2000M');
            testCase.verifyLessThan(max(abs(t - rec.truth)), 0.01);
            testCase.verifyEqual(tb.fs, 5, 'AbsTol', 1e-3);
        end

        function test2000SUnchanged(testCase)
            % 2000S: 1 ms tick at 10 Hz. The fit returns 1 ms and the
            % times match the counter at 1 kHz within the stamping floor.
            rec = testCase.synthRun('Tick', 1e-3, 'Fs', 10, 'Duration', 1800);
            [t, tb] = pf2_base.nirCounterTimebase(rec.pc, rec.counter, 'Model', 'Model 2000S HD');
            old = rec.pc(1) + (rec.counter - rec.counter(1)) / 1000;
            testCase.verifyEqual(tb.pooledTick, 1e-3, 'RelTol', 5e-6);
            testCase.verifyEqual(tb.fs, 10, 'AbsTol', 1e-4);
            testCase.verifyLessThan(max(abs(t - old)), 0.04);
            testCase.verifyLessThan(max(abs(t - rec.truth)), 0.01);
        end

        function testPCRestartsDuringBaseline(testCase)
            % PC clock restarts during the baseline: the PC column restarts
            % several times while the counter continues; one counter reset
            % falls where the PC clock is continuous. All times end up in the
            % final PC frame.
            rec = testCase.synthRun('Tick', 33/32768, 'Fs', 5, 'Duration', 1500, ...
                'RestartAt', [55 80 120 180], 'ResetsAt', 100);
            [t, tb] = pf2_base.nirCounterTimebase(rec.pc, rec.counter, 'Model', '2000M');
            testCase.verifyEqual(tb.pcRestarts, 4);
            testCase.verifyEqual(tb.counterResets, 1);
            testCase.verifyLessThan(max(abs(t - rec.truth)), 0.01);
            testCase.verifyTrue(all(diff(t) > 0));
        end

        function testClockStepsFollowPC(testCase)
            % A PC clock that steps back 90 ms and later jumps ahead 70 ms
            % (time-sync corrections): the tick is still fitted correctly
            % and samples after the last change follow the PC clock
            rec = testCase.synthRun('Tick', 1e-3, 'Fs', 10, 'Duration', 900);
            back = rec.truth >= 540;
            ahead = rec.truth >= 720;
            rec.pc(back) = rec.pc(back) - 0.090;
            rec.pc(ahead) = rec.pc(ahead) + 0.070;
            [t, tb] = pf2_base.nirCounterTimebase(rec.pc, rec.counter, 'Model', '2000S');
            testCase.verifyEqual(tb.pcRestarts, 1);
            testCase.verifyEqual(tb.pcJumps, 1);
            testCase.verifyTrue(all(isnan(tb.pieces.FittedTick) | ...
                abs(tb.pieces.FittedTick / 1e-3 - 1) < 50e-6));
            final = rec.truth - 0.090 + 0.070;   % PC frame after the last change
            testCase.verifyLessThan(max(abs(t(ahead) - final(ahead))), 0.01);
        end

        function testBacklogIsNotSplit(testCase)
            % Delivery latency that grows to 30 s (a backlog) keeps the
            % counter timing in one piece; the latency is reported
            rec = testCase.synthRun('Tick', 1e-3, 'Fs', 10, 'Duration', 1200);
            late = rec.truth > 900;
            rec.pc(late) = rec.pc(late) + 30 * ((rec.truth(late) - 900) / 300).^3;
            [t, tb] = pf2_base.nirCounterTimebase(rec.pc, rec.counter, 'Model', '2000S');
            testCase.verifyEqual(height(tb.pieces), 1);
            testCase.verifyEqual(tb.pcJumps, 0);
            testCase.verifyLessThan(max(abs(t - rec.truth)), 0.01);
            testCase.verifyGreaterThan(max(tb.latency), 25);
        end

        function testCounterPauseAtDropout(testCase)
            % An 8 s outage across which the counter advances only 4 s: the
            % samples after it arrive 4 s later than the counter predicts,
            % so the gap comes from the PC clock
            rec = testCase.synthRun('Tick', 33/32768, 'Fs', 5, 'Duration', 600, ...
                'DropAt', 300, 'DropCount', 40);
            after = rec.truth > rec.truth(1) + 300;   % truth starts at the PC clock origin
            rec.counter(after) = rec.counter(after) - round(4 / (33/32768));
            [t, tb] = pf2_base.nirCounterTimebase(rec.pc, rec.counter, 'Model', '2000M');
            testCase.verifyEqual(tb.counterPauses, 1);
            testCase.verifyEqual(sum(strcmp(tb.gaps.Kind, 'counter pause')), 1);
            testCase.verifyLessThan(max(abs(t - rec.truth)), 0.01);
        end

        function testWrongModelWarns(testCase)
            % 2000M data read with the 1 ms default: the fitted tick is
            % used and the mismatch is warned
            rec = testCase.synthRun('Tick', 33/32768, 'Fs', 5, 'Duration', 1200);
            [t, tb] = testCase.verifyWarning(@() pf2_base.nirCounterTimebase( ...
                rec.pc, rec.counter, 'Model', '2000S'), 'pf2:importNIR:tickMismatch');
            testCase.verifyEqual(tb.pooledTick, 33/32768, 'RelTol', 1e-5);
            testCase.verifyLessThan(max(abs(t - rec.truth)), 0.01);
        end

        function testImportNIR2000MFile(testCase)
            % End to end: a COBI Studio Modern 2000M .nir file imports with
            % fs = 5.000 Hz and the counter time base in info.timebase
            folder = tempname;
            mkdir(folder);
            testCase.addTeardown(@() rmdir(folder, 's'));
            rec = testCase.synthRun('Tick', 33/32768, 'Fs', 5, 'Duration', 900, 'ResetsAt', 500);
            fname = fullfile(folder, 'TB_999_200101_100000_Dev1_P1_Sub999.nir');
            testCase.writeNir(fname, rec, 60);

            prevGUI = pf2_base.channelCheckGUIEnabled(false);
            testCase.addTeardown(@() pf2_base.channelCheckGUIEnabled(prevGUI));
            data = pf2.import.importNIR(fname, false, false);
            testCase.verifyEqual(data.fs, 5, 'AbsTol', 1e-3);
            testCase.verifyTrue(isfield(data.info, 'timebase'));
            testCase.verifyEqual(data.info.timebase.counterResets, 1);
            testCase.verifyEqual(size(data.raw, 2), 55, 'Counter column should be dropped');
            testCase.verifyLessThan(max(abs(data.time - rec.truth)), 0.01);
        end
    end

    methods (Access = private)
        function rec = synthRun(~, varargin)
            % SYNTHRUN Synthetic recording with known true sample times
            %   Counter resets restart the counter after a 2 s gap; PC
            %   restarts subtract the elapsed PC time; stalls hold samples
            %   for 0.3-0.9 s and deliver them together; DropAt removes
            %   DropCount samples (default 5, 1 s at 5 Hz).
            p = inputParser;
            p.addParameter('Tick', 1e-3);
            p.addParameter('Fs', 10);
            p.addParameter('Duration', 600);
            p.addParameter('ResetsAt', []);
            p.addParameter('RestartAt', []);
            p.addParameter('StallsAt', []);
            p.addParameter('DropAt', []);
            p.addParameter('DropCount', 5);
            p.parse(varargin{:});
            o = p.Results;
            rng(7);
            truth = (0:round(o.Duration * o.Fs) - 1)' / o.Fs;
            seg = ones(size(truth));
            for k = 1:numel(o.ResetsAt)
                seg = seg + (truth >= o.ResetsAt(k));
            end
            truth = truth + 2 * (seg - 1);
            counter = zeros(size(truth));
            for s = 1:max(seg)
                r = seg == s;
                counter(r) = 1000 * s + floor((truth(r) - truth(find(r, 1))) / o.Tick);
            end
            pc = 50 + truth + 0.003 + 0.030 * rand(size(truth));
            for st = o.StallsAt
                i = find(truth >= st, 1);
                L = 0.3 + 0.6 * rand;
                k = i:find(truth >= truth(i) + L, 1);
                pc(k) = max(pc(k), pc(i) + L);
            end
            final = 50;
            for k = 1:numel(o.RestartAt)
                after = truth >= o.RestartAt(k);
                shift = pc(find(after, 1)) - 0.2;
                pc(after) = pc(after) - shift;
                final = final - shift;
            end
            keep = true(size(truth));
            if ~isempty(o.DropAt)
                i = find(truth >= o.DropAt, 1);
                keep(i:i+o.DropCount-1) = false;
            end
            rec.pc = pc(keep);
            rec.counter = counter(keep);
            rec.truth = final + truth(keep);   % in the final PC frame
        end

        function writeNir(~, fname, rec, nBaseline)
            % WRITENIR Write a COBI Studio Modern 2000M .nir file (time, 54
            % intensity columns, sample counter); the first nBaseline rows
            % form the baseline block
            fid = fopen(fname, 'w');
            c = onCleanup(@() fclose(fid));
            nl = sprintf('\r\n');
            fprintf(fid, ['COBI Studio Modern Light Data File\t1.2.7654.28485' nl ...
                'Start Time:\tWed Jan 01 10:00:00.000 2020' nl ...
                'SubjectID:\t999\tData Source:\tDevice 1, Model 2000M Imager, Port 1, HD, 18 optodes' nl ...
                'Start Code:\t1000000000000\t40000' nl 'Freq Code:\t10000000' nl ...
                'Current:\t30' nl 'Gains:\t5' nl 'Other:\tNone' nl ...
                '-2\tBaseline Started' nl]);
            vals = 1000 + round(500 * rand(numel(rec.pc), 54));
            row = @(i) [sprintf('%.3f', rec.pc(i)), sprintf('\t%d', vals(i, :)), ...
                sprintf('\t%d', rec.counter(i)), nl];
            for i = 1:nBaseline
                fprintf(fid, '%s', row(i));
            end
            fprintf(fid, ['-3\tBaseline values' nl '0' sprintf('\t%.2f', mean(vals(1:nBaseline, :))) nl ...
                '-4\tBaseline end' nl]);
            for i = nBaseline+1:numel(rec.pc)
                fprintf(fid, '%s', row(i));
            end
            fprintf(fid, ['-1\tDevice Stopped' nl]);
        end
    end
end
