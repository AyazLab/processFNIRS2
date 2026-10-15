function segments = extractBlocks(data, varargin)
% EXTRACTBLOCKS Extract each block as a separate fNIRS struct
%
% Takes an fNIRS data structure and a block definition array (from
% defineBlocks) and extracts each block as a separate fNIRS struct.
% Returns a cell array ready for exploreFNIRS.core.Experiment.
%
% Blocks can be provided explicitly as the second argument or read
% from data.blocks (set by defineBlocks with 'Embed', true). When
% data is a cell array, each element is extracted and results are
% concatenated.
%
% Syntax:
%   segments = pf2.data.extractBlocks(data, blocks)
%   segments = pf2.data.extractBlocks(data, blocks, 'Name', Value)
%   segments = pf2.data.extractBlocks(data)                % uses data.blocks
%   segments = pf2.data.extractBlocks(data, 'Name', Value) % uses data.blocks
%   segments = pf2.data.extractBlocks(cellData)             % cell array input
%
% Inputs:
%   data   - fNIRS data structure with time-series fields (.HbO, .time, etc.)
%            or a cell array of fNIRS structs (each with .blocks)
%   blocks - (Optional) Block definition struct array from pf2.data.defineBlocks
%            Each element must have .startTime, .endTime, and .info fields.
%            If omitted, data.blocks is used.
%
% Name-Value Parameters:
%   'PreTime'        - Seconds to include before block start. Overrides Buffer
%                      for the pre side when given (default: from Buffer).
%   'PostTime'       - Seconds to include after block end. Overrides Buffer for
%                      the post side when given (default: from Buffer).
%   'Buffer'         - Symmetric padding in seconds applied to BOTH sides when
%                      the corresponding PreTime/PostTime is not given
%                      (default: 2). With no window argument at all, the
%                      default Buffer = 2 s is used and a note is emitted
%                      (pf2:extractBlocks:defaultBuffer) whenever this default
%                      path is taken (i.e. on every call with no window given).
%   'BaselineWindow' - [start, end] relative to block start for baseline
%                      subtraction, e.g. [-5, 0] (default: [])
%   'SetT0'          - Shift time so block start = 0 (default: true)
%   'OverwriteInfo'  - Allow block.info fields to overwrite parent data.info
%                      fields of the same name (default: true). When false,
%                      parent fields are preserved and block.info only adds
%                      new fields.
%   'SkipInvalid'    - Skip blocks outside data time range (default: true)
%   'RejectByAux'    - Reject epochs overlapping accelerometer-flagged motion.
%                      Pass the accelerometer Aux signal name, or true to
%                      auto-detect an ACCEL-type signal (default: '' = off).
%   'AuxMotionFraction' - Max tolerated fraction of a block's samples that may
%                      fall in flagged motion before the epoch is dropped
%                      (default: 0.2). Only used with RejectByAux.
%   'AuxMotionThresh' - Absolute motion-metric threshold passed to
%                      accelMotionDetect (default: [] = adaptive MAD threshold).
%
% Outputs:
%   segments - Cell array {1 x N} of fNIRS structs, one per valid block
%              Each struct has merged .info from parent data and block.
%
% Algorithm:
%   1. For each block, compute extraction window with PreTime/PostTime
%   2. Optionally compute baseline window relative to block start
%   3. Call pf2.data.split to extract the time window
%   4. Optionally shift time with pf2.data.setT0 so block onset = 0
%   5. Merge parent data.info and block.info into segment.info
%
% Example:
%   blocks = pf2.data.defineBlocks(data, 'StartMarker', 50, 'EndMarker', 51);
%   segments = pf2.data.extractBlocks(data, blocks, ...
%       'PreTime', 5, 'PostTime', 2, ...
%       'BaselineWindow', [-5, 0], 'SetT0', true);
%
%   % Symmetric padding on both sides with Buffer
%   segments = pf2.data.extractBlocks(data, blocks, 'Buffer', 10);
%
%   % Prevent block info from overwriting parent subject info
%   segments = pf2.data.extractBlocks(data, 'OverwriteInfo', false);
%
%   % Using embedded blocks
%   data = pf2.data.defineBlocks(data, [49,50], 30, 'Embed', true);
%   segments = pf2.data.extractBlocks(data, 'PreTime', 5);
%
%   % Cell array of subjects with embedded blocks
%   segments = pf2.data.extractBlocks(allData);
%
%   % Feed directly to Experiment
%   ex = exploreFNIRS.core.Experiment(segments);
%
% See also: pf2.data.defineBlocks, pf2.data.split, pf2.data.setT0

% Inputs are parsed with pf2_base.args rather than an arguments block so
% the function also runs under GNU Octave. Spec rows are {name, default,
% size, class, validators}.
[blocks, opts] = pf2_base.args.parse('extractBlocks', varargin, {
    'blocks', ([]), '', '', {}
    }, {
    'PreTime',           ([]), '', '', {@mustBeNumeric}
    'PostTime',          ([]), '', '', {@mustBeNumeric}
    'Buffer',            ([]), '', '', {}
    'BaselineWindow',    ([]), '', '', {@mustBeNumeric}
    'SetT0',             (true), '1,1', 'logical', {}
    'OverwriteInfo',     (true), '1,1', 'logical', {}
    'CopyInfo',          (true), '1,1', 'logical', {}
    'SkipInvalid',       (true), '1,1', 'logical', {}
    'RejectByAux',       (''), '', '', {}
    'AuxMotionFraction', (0.2), '1,1', '', {@mustBeNumeric}
    'AuxMotionThresh',   ([]), '', '', {}
    });

% --- Cell array input: iterate and concatenate ---
if iscell(data)
    fwd = namedargs2cell(opts);
    segments = {};
    for i = 1:numel(data)
        segs = pf2.data.extractBlocks(data{i}, blocks, fwd{:});
        segments = [segments, segs]; %#ok<AGROW>
    end
    return;
end

% --- Resolve blocks: explicit argument or data.blocks ---
if ~isempty(blocks) && isstruct(blocks)
    % Guard: a data struct carrying embedded blocks (from defineBlocks with
    % 'Embed', true, which is the default) is easy to pass here by mistake.
    % It has a .blocks field but no .startTime, so detect it and use its
    % blocks, or give an actionable error instead of failing later with a
    % cryptic "Unrecognized field 'startTime'".
    if ~isfield(blocks, 'startTime')
        if isfield(blocks, 'blocks')
            blocks = blocks.blocks;
        else
            error('pf2:extractBlocks:badBlocks', ...
                ['Second argument is a struct but not a block array (no ''startTime'' field). ', ...
                 'Either pass a block array from pf2.data.defineBlocks(..., ''Embed'', false), ', ...
                 'or pass the embedded data struct as the FIRST argument: ', ...
                 'pf2.data.extractBlocks(data).']);
        end
    end
else
    if isfield(data, 'blocks') && ~isempty(data.blocks)
        blocks = data.blocks;
    else
        error('pf2:extractBlocks:noBlocks', ...
            'No blocks provided and data.blocks is empty. Call defineBlocks first.');
    end
end

% Resolve the extraction window. Precedence: an explicit PreTime/PostTime
% overrides for its side; otherwise the Buffer value (default 2 s) is applied
% to both sides. When the user passes no window argument at all, the default
% Buffer is used and an info-level note is emitted below.
% Empty defaults double as the "not given" sentinels the one-time note below
% keys on (formerly inputParser p.UsingDefaults).
gavePre    = ~isempty(opts.PreTime);
gavePost   = ~isempty(opts.PostTime);
gaveBuffer = ~isempty(opts.Buffer);
if gaveBuffer
    buffer = opts.Buffer;
else
    buffer = 2;
end

if gavePre
    preTime = opts.PreTime;
else
    preTime = buffer;
end
if gavePost
    postTime = opts.PostTime;
else
    postTime = buffer;
end

% This note is emitted when the default Buffer is used because NO window control
% was given at all (the pure default path), so a 15 s block does not silently
% inherit a surprise window. It is suppressed when a BaselineWindow is supplied
% (a deliberate epoch spec) and fires at most ONCE per session so batch loops
% are not flooded.
gaveBaseline = ~isempty(opts.BaselineWindow);
persistent defaultBufferNoted
if ~gavePre && ~gavePost && ~gaveBuffer && ~gaveBaseline && isempty(defaultBufferNoted)
    defaultBufferNoted = true;
    warning('pf2:extractBlocks:defaultBuffer', ...
        ['No window given; using default Buffer = 2 s (both sides); ', ...
         'pass ''Buffer'' or ''PreTime''/''PostTime'' to set your own. ', ...
         '(This note is shown once per session.)']);
end

blWindow = opts.BaselineWindow;
doSetT0 = opts.SetT0;
overwriteInfo = opts.OverwriteInfo;
skipInvalid = opts.SkipInvalid;

% --- Resolve aux motion mask for trial rejection (computed once) ----------
rejectByAux = opts.RejectByAux;
auxMotionFraction = opts.AuxMotionFraction;
doRejectAux = false;
auxMotionMask = [];
if (islogical(rejectByAux) && rejectByAux) || ...
        (~islogical(rejectByAux) && ~isempty(char(string(rejectByAux))))
    detectArgs = {};
    if ~islogical(rejectByAux)
        detectArgs = {'Signal', char(string(rejectByAux))};
    end
    if ~isempty(opts.AuxMotionThresh)
        detectArgs = [detectArgs, {'Threshold', opts.AuxMotionThresh}]; %#ok<AGROW>
    end
    try
        auxMotionMask = pf2_base.fnirs.accelMotionDetect(data, detectArgs{:});
        doRejectAux = true;
    catch ME
        warning('pf2:extractBlocks:auxRejectFailed', ...
            'Aux motion rejection skipped: %s', ME.message);
    end
end

if isempty(blocks)
    segments = {};
    return;
end

% Get data time range for validation
dataTimeMin = min(data.time);
dataTimeMax = max(data.time);

segments = {};
for k = 1:length(blocks)
    blk = blocks(k);

    % Compute extraction window
    extractStart = blk.startTime - preTime;
    extractEnd = blk.endTime + postTime;

    % Validate time range
    if skipInvalid
        if extractStart > dataTimeMax || extractEnd < dataTimeMin
            continue;
        end
    end

    % Aux-conditioned rejection: drop this epoch if too many of its samples
    % fall in accelerometer-flagged motion windows (the block interval itself,
    % not the padded extraction window).
    if doRejectAux
        inBlock = data.time >= blk.startTime & data.time <= blk.endTime;
        if any(inBlock) && mean(auxMotionMask(inBlock)) > auxMotionFraction
            continue;
        end
    end

    % Extract segment using split (without baseline - apply separately)
    segment = pf2.data.split(data, extractStart, extractEnd);

    % Apply baseline subtraction if requested
    if ~isempty(blWindow)
        blAbsStart = blk.startTime + blWindow(1);
        blAbsEnd = blk.startTime + blWindow(2);

        if blAbsEnd > blAbsStart
            % Extract baseline period from original data
            blSeg = pf2.data.split(data, blAbsStart, blAbsEnd);

            % Subtract baseline mean from hemoglobin fields
            hbFields = {'HbO', 'HbR', 'HbDiff', 'HbTotal', 'CBSI'};
            for f = 1:length(hbFields)
                fn = hbFields{f};
                if isfield(segment, fn) && isfield(blSeg, fn)
                    segment.(fn) = segment.(fn) - mean(blSeg.(fn), 1, 'omitnan');
                end
            end
        end
    end

    % Skip empty/invalid segments
    if isfield(segment, 'empty') && segment.empty
        if skipInvalid
            continue;
        end
    end

    % Shift time so block start = 0
    if doSetT0
        segment = pf2.data.setT0(segment, blk.startTime);
    end

    % Remove parent blocks from segment (segments are individual blocks)
    if isfield(segment, 'blocks')
        segment = rmfield(segment, 'blocks');
    end

    % Merge info: start with parent data.info, overlay block.info
    mergedInfo = struct();
    if isfield(data, 'info')
        parentFields = fieldnames(data.info);
        for f = 1:length(parentFields)
            mergedInfo.(parentFields{f}) = data.info.(parentFields{f});
        end
    end

    % Overlay block-level info
    if isstruct(blk.info)
        blockFields = fieldnames(blk.info);
        for f = 1:length(blockFields)
            if overwriteInfo || ~isfield(mergedInfo, blockFields{f})
                mergedInfo.(blockFields{f}) = blk.info.(blockFields{f});
            end
        end
    end

    segment.info = mergedInfo;

    segments{end+1} = segment; %#ok<AGROW>
end

end
