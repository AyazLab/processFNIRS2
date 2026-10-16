function [markerTimes, tableMrkTimes, matchedPatterns] = getMarkers(fNIR, varargin)
% GETMARKERS Extract event marker times matching specified codes or patterns
%
% Searches fNIRS marker data to find events matching specified marker codes
% or sequential patterns. Returns marker times for use in epoching, event
% alignment, or stimulus analysis.
%
% Syntax:
%   markerTimes = pf2.data.getMarkers(fNIR, markerCode)
%   markerTimes = pf2.data.getMarkers(fNIR, startMarker, endMarker)
%   markerTimes = pf2.data.getMarkers(fNIR, markerPattern)
%   [markerTimes, tableMrkTimes, matchedPatterns] = pf2.data.getMarkers(...)
%
% Inputs:
%   fNIR           - fNIRS data structure with .markers field (canonical
%                    marker table: .Time .Code .Duration .Amplitude + extras)
%                    Or a marker table/matrix directly
%   markerCode     - Single marker code(s) to find:
%                    - Scalar: Find all markers with this code
%                    - [50,51] row vector: Find sequence 50 followed by 51
%                    - [50;51] column vector: Find markers 50 OR 51
%   startMarker    - Start marker code(s) for paired extraction
%   endMarker      - End marker code(s) for paired extraction
%   markerPattern  - Cell array of codes/patterns: {25, [50,51]}
%                    Finds marker 25 AND pattern 50-51
%
% Name-Value Parameters:
%   'markerColumn'       - Column index for marker values (default: 2)
%   'markerVariableName' - Variable name in table (overrides markerColumn)
%   'timeColumn'         - Column index for marker times (default: 1)
%   'returnIndices'      - Return indices instead of times (default: false)
%   'exactMatch'         - Require exact sequence without interleaving (default: false)
%
% Outputs:
%   markerTimes      - Matrix of marker times [N x 2] (start, end)
%                      Or [N x 1] for single marker queries
%   tableMrkTimes    - Table with marker details and matched times
%   matchedPatterns  - Cell array of matched pattern information
%
% Pattern Matching:
%   - Row vectors [50,51]: Sequential pattern (50 THEN 51)
%   - Column vectors [50;51]: Either marker (50 OR 51)
%   - Cell arrays {25,[50,51]}: Multiple patterns (25 AND sequence 50-51)
%   - Interleaving markers allowed unless exactMatch=true
%
% Example:
%   % Find all instances of marker 49
%   times = pf2.data.getMarkers(data, 49);
%
%   % Find start/end pairs for markers 50 and 51
%   times = pf2.data.getMarkers(data, 50, 51);
%
%   % Find pattern: marker 25 followed by sequence 50-51
%   times = pf2.data.getMarkers(data, {25, [50,51]});
%
%   % Get indices instead of times
%   idx = pf2.data.getMarkers(data, 49, 'returnIndices', true);
%
% See also: pf2.data.split, pf2.data.setT0, pf2.data.resample



% Inputs are parsed with pf2_base.args rather than an arguments block so
% the function also runs under GNU Octave. Spec rows are {name, default,
% size, class, validators}.
[markersStart, markersEnd, opts] = pf2_base.args.parse('getMarkers', varargin, {
    'markersStart', ([]), '', '', {@mustBeNumericOrLogical}
    'markersEnd',   ([]), '', '', {@mustBeNumericOrLogical}
    }, {
    'markerPattern',      ([]), '', '', {}
    'markerColumn',       (2), '', '', {@mustBeNumericOrLogical}
    'markerVariableName', (''), '', '', {@mustBeText}
    'timeColumn',         (1), '', '', {@mustBeNumericOrLogical}
    'returnIndices',      (false), '', '', {@mustBeNumericOrLogical}
    'exactMatch',         (false), '', '', {@mustBeNumericOrLogical}
    'sortTimes',          (false), '', '', {@mustBeNumericOrLogical}
    });

validfNIR_Input = @(x) (isstruct(x) && (isfield(x,'raw')||isfield(x,'time')||isfield(x,'info')));

markerPatternIn=opts.markerPattern;
markerColumn=opts.markerColumn;
markerVariableName=opts.markerVariableName;
timeColumn=opts.timeColumn;
returnIndices=opts.returnIndices;
exactMatch=opts.exactMatch;
sortTimes=opts.sortTimes;

if(iscell(markersStart))
    markerPatternIn=markersStart;
    markersStart=[];
end


if(timeColumn<=0)
    returnIndices=true;
end

isFNIRstruct=validfNIR_Input(fNIR);

if(isempty(markersEnd)&&isempty(markerPatternIn)) % if only start patterns are provided, only start times are returned
    startMrkOnly=true;
else
    startMrkOnly=false;
end

if(~isFNIRstruct)
    %processing data as just markers
    temp=fNIR;
    fNIR=[];
    fNIR.markers=temp;
    
    if(istable(fNIR.markers)&&~isempty(markerVariableName))
        markerColumn=find(ismember(fNIR.markers.Properties.VariableNames,markerVariableName));
    end
elseif(isFNIRstruct&&~isfield(fNIR,'markers')||size(fNIR.markers,1)<1)
    warning('fNIR struct has no marker data')
    markerTimes=[];
    return;
end

% --- Fast path: pure OR query (column vector of codes) -------------------
% A column vector such as [50;51] means "markers with code 50 OR 51".
% The general regex-based matcher below builds a separate single-code
% pattern per row and can drop matches for multi-code OR queries, so handle
% this common case directly with set membership. Returns onset times for any
% of the requested codes, sorted chronologically. Scalar codes (1x1) and
% sequence row vectors ([50,51]) fall through to the general matcher.
isPureOR = ~iscell(markersStart) && isnumeric(markersStart) ...
    && size(markersStart,1) > 1 && size(markersStart,2) == 1 ...
    && isempty(markersEnd) && isempty(markerPatternIn) && ~exactMatch;
if isPureOR
    mVals = fNIR.markers(:, markerColumn);
    if istable(mVals); mVals = mVals{:,1}; end
    codes = unique(markersStart(:));
    sel = ismember(mVals, codes);

    if ~any(sel)
        warning('pf2:getMarkers:noMatch', ...
            'None of the requested marker codes (%s) were found in the data.', ...
            mat2str(codes(:)'));
        markerTimes = [];
        tableMrkTimes = {};
        matchedPatterns = cell(0);
        return;
    end

    if timeColumn <= 0 || returnIndices
        tVals = find(sel);
    else
        tVals = fNIR.markers(sel, timeColumn);
        if istable(tVals); tVals = tVals{:,1}; end
    end
    selCodes = mVals(sel);

    [tVals, ord] = sort(tVals);
    selCodes = selCodes(ord);

    markerTimes = tVals;                 % Nx1 onset times (start-only semantics)
    tableMrkTimes = table(tVals, selCodes, 'VariableNames', {'Time','Code'});
    matchedPatterns = {codes(:)'};
    return;
end

uMatchingMarkers=[];

for i=1:size(markersStart,1)
   if(iscell(markersStart(i)))
       uMatchingMarkers=[uMatchingMarkers,unique(markersStart{i})];
   else
       uMatchingMarkers=[uMatchingMarkers,unique(markersStart(i,:))];
   end
end

for i=1:size(markersEnd,1)
   if(iscell(markersEnd(i)))
       uMatchingMarkers=[uMatchingMarkers,unique(markersEnd{i})];
   else
       uMatchingMarkers=[uMatchingMarkers,unique(markersEnd(i,:))];
   end
end

for i=1:size(markerPatternIn,1)
   if(iscell(markerPatternIn(i)))
       uMatchingMarkers=[uMatchingMarkers,unique(markerPatternIn{i})];
   else
       uMatchingMarkers=[uMatchingMarkers,unique(markerPatternIn(i,:))];
   end
end


markerVals=fNIR.markers(:,markerColumn);



if(istable(markerVals))
    markerVals=markerVals{:,1};
end

if(~exactMatch)
    % non-exact match discards all misc markers before match
    reducedIndex=find(ismember(markerVals,uMatchingMarkers));
else
    % exact match retains all misc markers before match
    reducedIndex=[1:size(markerVals,1)]';
end
reducedMarkers=fNIR.markers(reducedIndex,:);

if(timeColumn<=0)
    reducedTimes=reducedIndex;
else
    reducedTimes=reducedMarkers(:,timeColumn);
end

if(istable(reducedTimes))
    reducedTimes=reducedTimes{:,1};
end

if(isempty(reducedTimes))
    markerTimes=[];
    tableMrkTimes={};
    matchedPatterns=cell(0);
    return;
end

if(isnumeric(markerVals(1))&&isnumeric(reducedTimes(1)))
    returnArray=true;
else
    returnArray=false;
end

[uMarkers,~,uMrkIdx]=unique(reducedMarkers(:,markerColumn));

if(istable(uMarkers))
    uMarkers=uMarkers{:,1};
end

if(isempty(uMarkers))
    markerTimes=[];
    tableMrkTimes={};
    matchedPatterns=cell(0);
    return;
end

%for i=1:length(uMatchingMarkers)
%   uMatchIdx(i)=find(uMatchingMarkers(i)==uMarkers);
%end



if(isempty(markerPatternIn))
    % convert start and end terms into ucodes (characters)
    markersStartStr=cell(0);
    for i=1:size(markersStart,1)
       if(iscell(markersStart(i)))
           startVals=markersStart{i};
       else
           startVals=markersStart(i,:);
       end
       
       uStartVals=nan(size(startVals));
       missingMarkers =0;
       for j=1:length(startVals)
           if(sum(startVals(j)==uMarkers))
                uStartVals(j)=find(startVals(j)==uMarkers);
           else
                % if markers are not in data
                missingMarkers=missingMarkers+1;
                uStartVals(j)=length(uMarkers)+missingMarkers;
           end
       end
       
       markersStartStr{i}=char(uStartVals+47); %convert to ascii
    end
    

    % convert end terms into ucodes (characters)
    markersEndStr=cell(0);
    for i=1:size(markersEnd,1)
       if(iscell(markersEnd(i)))
           endVals=markersEnd{i};
       else
           endVals=markersEnd(i,:);
       end
       
       uEndVals=nan(size(endVals));
       for j=1:length(endVals)
           uEndVals(j)=find(endVals(j)==uMarkers);
       end
       
       markersEndStr{i}=char(uEndVals+47); %convert to ascii
    end
    

    
    %merge strings for start and end
    
    markerPatternChar=cell(0);
    for i=1:size(markersStart,1)
       if(size(markersEnd,1)==0)
            markerPatternChar{i}=sprintf('%s',markersStartStr{i});
            matchedPatterns{i}=markersStart(i,:);
       elseif(size(markersEnd,1)==1)
           markerPatternChar{i}=sprintf('%s\\w*?%s',markersStartStr{i},markersEndStr{1});
           matchedPatterns{i,1}=markersStart(i,:);
           matchedPatterns{i,2}=markersEnd(1,:);
       elseif(size(markersEnd,1)==size(markersStart,1))
           markerPatternChar{i}=sprintf('%s?%s',markersStartStr{i},markersEndStr{i});
           matchedPatterns{i,1}=markersStart(i,:);
           matchedPatterns{i,2}=markersEndStr(i,:);
       elseif(size(markersStart,1)==1)
           for j=1:size(markersEnd,1)
               markerPatternChar{j}=sprintf('%s\\w*?%s',markersStartStr{1},markersEndStr{j});
               matchedPatterns{j,1}=markersStart(1,:);
               matchedPatterns{j,2}=markersEndStr(j,:);
           end
       else
          error('pf2:getMarkers:markerMismatch', 'Marker mismatch\nPlease supply 1 start marker for each end marker or only one start/end marker');
       end
        
    end
    
else
    %convert pattern into ucodes
    markerPatternNum=markerPatternIn;
    markerPatternChar=cell(0);
    matchedPatterns=cell(0);
    for i=1:size(markerPatternNum,1)
        % For each markerPattern
        if(iscell(markerPatternNum(i)))
           patternVals=markerPatternNum{i};
       else
           patternVals=markerPatternNum(i,:);
        end
       
       % recode values into unique marker ids
       uPatternVals=nan(size(patternVals));
       for j=1:length(uMarkers)
           matchedVals=patternVals==uMarkers(j);
           if(any(matchedVals))
                uPatternVals(matchedVals)=j;
           end
       end
       
       if(any(isnan(uPatternVals)))
           markerPatternChar{i}='';
           if(iscell(markerPatternNum(i)))
                matchedPatterns(i)=markerPatternNum(i);
           else
                 matchedPatterns{i}=markerPatternNum(i);
           end
           continue
       else
       
           markersPatternStr{i}=uValsToString(uPatternVals); %convert to ascii

           markerPatternChar{i}=char(markersPatternStr{i});

           if(iscell(markerPatternNum(i)))
                matchedPatterns(i)=markerPatternNum(i);
           else
                matchedPatterns{i}=markerPatternNum(i);
           end
       end
    end
end

regMrkStr=char(uValsToString(uMrkIdx)');

markerTimes=[];
tableMrkTimes=cell(0);
for i=1:size(markerPatternChar,1)
    if (~isempty(markerPatternChar{i}))
        clean_mrk_str=onlyPatternMrk(markerPatternChar{i},regMrkStr);
        [patterns,startIdx,endIdx]=regexp(clean_mrk_str,markerPatternChar{i},'match');
        startIdx=startIdx(:);
        endIdx=endIdx(:);
        tableMrkTimes{i}=table(reducedTimes(startIdx),reducedTimes(endIdx),ones(length(startIdx),1)*i,reducedIndex(startIdx),reducedIndex(endIdx),reducedTimes(endIdx)-reducedTimes(startIdx));
        tableMrkTimes{i}.Properties.VariableNames={'StartTime','EndTime','PatternNum','StartIndex','EndIndex','TimeDiff'};

        markerTimes=[markerTimes;tableMrkTimes{i}];
    end
end

if(isempty(markerTimes))
   return; 
end

if(returnIndices)
   markerTimes=markerTimes(:,[4,5,3,1,2,6]);
end

if(sortTimes)
    markerTimes=sortrows(markerTimes,1);
end

if(returnArray)
   markerTimes=[markerTimes{:,1},markerTimes{:,2},markerTimes{:,3}]; 
end

if(length(markerPatternChar)==1)
   markerTimes=markerTimes(:,[1,2]);
   if(startMrkOnly)
       markerTimes=markerTimes(:,1);
       if(istable(markerTimes))
          markerTimes=markerTimes{:,1}; 
       end
   end
elseif(startMrkOnly)
   markerTimes=markerTimes(:,[1,3]);
end

end

function regMrkIdx=uValsToString(uVals)
    reg_numeric_idx=uVals<=10;
    reg_upper_idx=(~reg_numeric_idx)&uVals<=37;
    reg_lower_idx=(~reg_numeric_idx&~reg_upper_idx&uVals<=63);

    regMrkIdx=nan(size(uVals));
    regMrkIdx(reg_numeric_idx)=uVals(reg_numeric_idx)+47;
    regMrkIdx(reg_upper_idx)=uVals(reg_upper_idx)+64;
    regMrkIdx(reg_lower_idx)=uVals(reg_lower_idx)+96;
    if(max(uVals>63))
        error('pf2:getMarkers:tooManyMarkers', 'Too many unique markers');
    end
end

function cleanedMarkers=onlyPatternMrk(input_pattern,markers)


    if(ischar(input_pattern))
        input_pattern=double(input_pattern);
    end
    
    if(ischar(markers))
       markers=double(markers); 
       returnChar=true;
    else
       returnChar=false; 
    end
    
    uInput=unique(input_pattern);
    numInputs=length(uInput);
    
    markers(~ismember(markers,uInput))=0;
    
    if(returnChar)
        markers(markers==0)=',';
        markers=char(markers);
    end
    
    cleanedMarkers=markers;

end

