function [outfNIR] = split(varargin)
% SPLIT Extract time segment from fNIRS data with optional baseline correction
%
% Extracts a portion of fNIRS data between specified start and end times.
% Can apply baseline correction using either a portion of the extracted
% segment or a separate baseline recording.
%
% Syntax:
%   outfNIR = pf2.data.split(fNIR, startTime)
%   outfNIR = pf2.data.split(fNIR, startTime, endTime)
%   outfNIR = pf2.data.split(..., 'Name', Value)
%
% Inputs:
%   fNIR           - fNIRS data structure
%   startTime      - Start time in seconds (absolute or relative)
%                    If only startTime given, extracts from startTime to end
%   endTime        - End time in seconds (optional)
%   'segmentLength' - Alternative to endTime: duration in seconds
%                    endTime = startTime + segmentLength
%   'relative'     - Time interpretation flag (default: false)
%                    false: Times are absolute (from t=0 of recording)
%                    true: Times are relative to min(fNIR.time)
%   'blLength'     - Baseline period duration in seconds
%                    Subtracts baseline mean from extracted segment
%   'blStartTime'  - Baseline start time (default: 0 or startTime if relative)
%   'blfNIR'       - Separate fNIRS struct to use as baseline source
%                    Overrides blLength and blStartTime when provided
%
% Outputs:
%   outfNIR        - Extracted fNIRS structure containing:
%                    All fields truncated to requested time range
%                    Baseline-corrected if baseline options specified
%
% Algorithm:
%   1. Convert relative times to absolute if needed
%   2. Find sample indices for start/end times
%   3. Extract all data fields for time range
%   4. If baseline specified:
%      a. Extract baseline period
%      b. Compute mean for each channel
%      c. Subtract from extracted segment
%
% Example:
%   % Extract from t=561s to end
%   segment = pf2.data.split(data, 561);
%
%   % Extract t=200 to t=282
%   segment = pf2.data.split(data, 200, 282);
%
%   % Extract 60s segment starting 20s after recording begins (relative)
%   segment = pf2.data.split(data, 20, 'segmentLength', 60, 'relative', true);
%
%   % Extract with 10s baseline at start
%   segment = pf2.data.split(data, 20, 100, 'blLength', 10);
%
%   % Extract using separate baseline recording
%   segment = pf2.data.split(data, 20, 100, 'blfNIR', baselineData);
%
% See also: pf2.data.resample, pf2.data.getMarkers, pf2.data.setT0


pf2_base.ensureStatsFallbacks();  % ensure stats-toolbox fallbacks (nan*) are on the path before use

p=inputParser;

validfNIRInput = @(x) (isnumeric(x)&&length(x)>1) || (isstruct(x) && (isfield(x,'raw')||isfield(x,'time')||isfield(x,'info')));
validScalarNum = @(x) isnumeric(x) && isscalar(x);
validScalarPosNum = @(x) isnumeric(x) && isscalar(x) && (x > 0);

addRequired(p,'fNIR',validfNIRInput);
addOptional(p,'startTime',nan,validScalarNum);
addOptional(p,'endTime',nan,validScalarNum);
addOptional(p,'segmentLength',nan,validScalarPosNum);
addOptional(p,'relative',false,@islogical);
addOptional(p,'blLength',nan,validScalarPosNum);
addOptional(p,'blStartTime',nan,validScalarNum);
addParameter(p,'blEndTime',nan,validScalarNum);
addParameter(p,'blfNIR',[],validfNIRInput);
addParameter(p,'splitAux',true,@islogical);

parse(p,varargin{:});

fNIR=p.Results.fNIR;
startTime=p.Results.startTime;
endTime=p.Results.endTime;
segmentLength=p.Results.segmentLength;
blLength=p.Results.blLength;
blStartTime=p.Results.blStartTime;
blEndTime=p.Results.blEndTime;
relative=p.Results.relative;
blfNIR=p.Results.blfNIR;

splitAux=p.Results.splitAux;

if(~isstruct(fNIR))
    temp=fNIR;
    fNIR=[];
    fNIR.raw=temp;
    clear temp;
    
    fNIR.time=fNIR.raw(:,1);
end

if(isfield(fNIR,'info')&&(~isfield(fNIR,'time')&&~isfield(fNIR,'HbO')&&~isfield(fNIR,'raw')))
    fNIR.time=nan;
    outfNIR=fNIR;
    return;
end

if(~isempty(blfNIR)&&~isstruct(blfNIR)&&isnumeric(blfNIR))
    temp=blfNIR;
    blfNIR=[];
    blfNIR.raw=temp;
    clear temp;
    
    blfNIR.time=blfNIR.raw(:,1);
end

if(~isfield(fNIR,'time')&&isfield(fNIR,'raw'))
    if(~isempty(fNIR.raw))
        fNIR.time=fNIR.raw(:,1);
    else
        fNIR.time=[];
    end
end

if(isempty(fNIR.time))
    warning('empty time structure');
    outfNIR=fNIR;
    return;
end



if(relative) % Convert to absolute units here
    if(isnan(startTime))
        startTime=min(fNIR.time);
    elseif(startTime<0)
        error('pf2:split:negativeRelativeStart', 'Relative time cannot have a negative startTime');
    else
        startTime=min(fNIR.time)+startTime;  %Start time is X seconds from beginning
    end
    if(~isnan(endTime))  
        endTime=min(fNIR.time)+endTime;  %End time is X seconds from beginning
    else
        endTime=max(fNIR.time); %go to end if not defined by default
    end
else
    if(isnan(startTime))
        startTime=min(fNIR.time(1));
    end
    if(startTime<min(fNIR.time))
        warning('Start time precedes fNIR time');
    end
    if(isnan(endTime))
        endTime=max(fNIR.time); %go to end if not defined by default
    end
end

if(~isnan(segmentLength))
    endTime=startTime+segmentLength;  %%overwrite end time with segment length if given
    if(~isnan(p.Results.endTime))
       warning('EndTime is defined but segment Length is also defined, only using segment Length'); 
    end
end

if(endTime>max(fNIR.time))
    %endTime=max(fNIR.time);
    warning('pf2:split:endTimeClamped', ...
        ['End time (%.1f s) exceeds the recording length (%.1f s); ' ...
         'the segment is truncated to the available data.'], ...
        endTime, max(fNIR.time));
end

if(endTime<startTime)
   error('pf2:split:endBeforeStart', 'End Time (%.1f) precedes Start Time (%.1f). Use ''segmentLength'' argument to allow relative from startTime',endTime,startTime);
end

if(~isnan(blStartTime)&&~isnan(blEndTime))
    blLength=blEndTime-blStartTime;
    if(blLength<=0)
       error('pf2:split:invalidBaselineWindow', 'Baseline end must come after baseline start');
    end
end

if(~(isnan(blStartTime)&&isnan(blLength))) %if either is set use some default
    if(isnan(blStartTime))
       blStartTime=startTime;
    end
    if(isnan(blLength))
        blLength=10;
        warning('Baseline Length is undefined, using 10 second period'); 
    end
end

if(relative)
   blStartTime=blStartTime+min(fNIR.time); 
end

blEndTime=blStartTime+blLength;


if(~isnan(blEndTime)&&(blStartTime<startTime||blEndTime>endTime))
   warning('<!!> Using Basline period outside of selected segment');
end



hasRawField=isfield(fNIR,'raw');

if(hasRawField&&isempty(fNIR.raw))
    hasRawField=false;
    fNIR=rmfield(fNIR,'raw');
end

hasOxyField=isfield(fNIR,'HbO');



hasCARfield=isfield(fNIR,'CAR');
hasROIfield=isfield(fNIR,'ROI');


indexStart=find(fNIR.time>=startTime,1);
indexEnd=find(fNIR.time<=endTime,1,'last');

if(~isnan(blEndTime))
    blIndexStart=find(fNIR.time>=(blStartTime),1);
    blIndexEnd=find(fNIR.time>=(blEndTime),1);
    
    if(isempty(blIndexStart)||isempty(blIndexEnd)||(blIndexStart>blIndexEnd))
        warning('Invalid Baseline period');
       indexStart=[];   %If baseline period is invalid, set start time to be invalid too
    elseif(~isnan(blEndTime)&&(blEndTime>max(fNIR.time)||blStartTime<(min(fNIR.time))))
        warning('Baseline exists outside of fNIRS entirely');
        indexStart=[];   %If baseline period is invalid, set start time to be invalid too
    end
end

    


if((isempty(indexStart)||isempty(indexEnd))||(indexStart>indexEnd))
    warning('Invalid Block period');
    
    outfNIR.empty=true;
    
    if(hasOxyField)
        numCh=size(fNIR.HbO,2);
        outfNIR.HbO=nan*ones(1,numCh);
        outfNIR.HbR=nan*ones(1,numCh);
        outfNIR.HbDiff=nan*ones(1,numCh);
        outfNIR.CBSI=nan*ones(1,numCh);
        outfNIR.HbTotal=nan*ones(1,numCh);
    end
    
    if(hasCARfield)
       outfNIR.CAR.HbO=nan*ones(1,numCh);
        outfNIR.CAR.HbR=nan*ones(1,numCh);
        outfNIR.CAR.HbDiff=nan*ones(1,numCh);
        outfNIR.CAR.CBSI=nan*ones(1,numCh);
        outfNIR.CAR.HbTotal=nan*ones(1,numCh);
    end

    if(hasRawField)
        numRawCols=size(fNIR.raw,2);
        outfNIR.raw=nan*ones(1,numRawCols);
    end
    
    if(isfield(fNIR,'time'))
        outfNIR.time=startTime;
    end
else

     if(hasOxyField)
        outfNIR.HbO=fNIR.HbO(indexStart:indexEnd,:);
        outfNIR.HbR=fNIR.HbR(indexStart:indexEnd,:);
        outfNIR.HbDiff=fNIR.HbDiff(indexStart:indexEnd,:);
        outfNIR.CBSI=fNIR.CBSI(indexStart:indexEnd,:);
        outfNIR.HbTotal=fNIR.HbTotal(indexStart:indexEnd,:);
        
        
         if(~isempty(blfNIR))
                outfNIR.HbR=outfNIR.HbR-nanmean(blfNIR.HbR,1);
                outfNIR.HbO=outfNIR.HbO-nanmean(blfNIR.HbO,1);
                outfNIR.HbDiff=outfNIR.HbDiff-nanmean(blfNIR.HbDiff,1);
                outfNIR.HbTotal=outfNIR.HbTotal-nanmean(blfNIR.HbTotal,1);
                outfNIR.CBSI=outfNIR.CBSI-nanmean(blfNIR.CBSI,1);

         elseif(exist('blIndexStart'))
                if (~isempty(blIndexStart)&&~isempty(blIndexEnd))&&(blIndexStart<=blIndexEnd)
                %for i=1:length(outfNIR.HbR(1,:))
                   outfNIR.HbO=outfNIR.HbO-nanmean(fNIR.HbO(blIndexStart:blIndexEnd,:),1);
                   outfNIR.HbR=outfNIR.HbR-nanmean(fNIR.HbR(blIndexStart:blIndexEnd,:),1);
                   outfNIR.CBSI=outfNIR.CBSI-nanmean(fNIR.CBSI(blIndexStart:blIndexEnd,:),1);
                   outfNIR.HbDiff=outfNIR.HbDiff-nanmean(fNIR.HbDiff(blIndexStart:blIndexEnd,:),1);
                end
                %end
        end
     end
     
     if(hasCARfield)
        outfNIR.CAR.HbO=fNIR.CAR.HbO(indexStart:indexEnd,:);
        outfNIR.CAR.HbR=fNIR.CAR.HbR(indexStart:indexEnd,:);
        outfNIR.CAR.HbDiff=fNIR.CAR.HbDiff(indexStart:indexEnd,:);
        outfNIR.CAR.CBSI=fNIR.CAR.CBSI(indexStart:indexEnd,:);
        outfNIR.CAR.HbTotal=fNIR.CAR.HbTotal(indexStart:indexEnd,:);
     end

    if(hasRawField)
        outfNIR.raw=fNIR.raw(indexStart:indexEnd,:);
    end
    
    if(isfield(fNIR,'time'))
        outfNIR.time=fNIR.time(indexStart:indexEnd,1);
    end
    
    if(isfield(fNIR,'datetime'))
        outfNIR.datetime=fNIR.datetime(indexStart:indexEnd,1);
    end
    
    if(isfield(fNIR,'segmentTimes'))
        outfNIR.segmentTimes=fNIR.segmentTimes(indexStart:indexEnd,:);
    end
    

    if(isfield(fNIR,'t0')&&isdatetime(fNIR.t0))
        outfNIR.t0=fNIR.t0;

        outfNIR.datetime=fNIR.t0+duration(0,0,outfNIR.time);
    end
    
    if(hasROIfield)
        outfNIR.ROI=fNIR.ROI;

        if(pf2_base.isnestedfield(fNIR.ROI,'HbO'))
            outfNIR.ROI.HbO=fNIR.ROI.HbO(indexStart:indexEnd,:);
            outfNIR.ROI.HbR=fNIR.ROI.HbR(indexStart:indexEnd,:);
            outfNIR.ROI.HbDiff=fNIR.ROI.HbDiff(indexStart:indexEnd,:);
            outfNIR.ROI.CBSI=fNIR.ROI.CBSI(indexStart:indexEnd,:);
            outfNIR.ROI.HbTotal=fNIR.ROI.HbTotal(indexStart:indexEnd,:);
            
            if(~isempty(blfNIR))
                if(isfield(blfNIR,'ROI'))
                    outfNIR.ROI.HbR=outfNIR.ROI.HbR-nanmean(blfNIR.ROI.HbR,1);
                    outfNIR.ROI.HbO=outfNIR.ROI.HbO-nanmean(blfNIR.ROI.HbO,1);
                    outfNIR.ROI.HbDiff=outfNIR.ROI.HbDiff-nanmean(blfNIR.ROI.HbDiff,1);
                    outfNIR.ROI.HbTotal=outfNIR.ROI.HbTotal-nanmean(blfNIR.ROI.HbTotal,1);
                    outfNIR.ROI.CBSI=outfNIR.ROI.CBSI-nanmean(blfNIR.ROI.CBSI,1);
                else
                    error('pf2:split:noBaselineROI', 'Baseline has no Build ROI data');
                end
         
             elseif(exist('blIndexStart'))
                    if (~isempty(blIndexStart)&&~isempty(blIndexEnd))&&(blIndexStart<=blIndexEnd)
                    %for i=1:length(outfNIR.HbR(1,:))
                       outfNIR.ROI.HbO=outfNIR.ROI.HbO-nanmean(fNIR.ROI.HbO(blIndexStart:blIndexEnd,:),1);
                       outfNIR.ROI.HbR=outfNIR.ROI.HbR-nanmean(fNIR.ROI.HbR(blIndexStart:blIndexEnd,:),1);
                       outfNIR.ROI.CBSI=outfNIR.ROI.CBSI-nanmean(fNIR.ROI.CBSI(blIndexStart:blIndexEnd,:),1);
                       outfNIR.ROI.HbDiff=outfNIR.ROI.HbDiff-nanmean(fNIR.ROI.HbDiff(blIndexStart:blIndexEnd,:),1);
                       outfNIR.ROI.HbTotal=outfNIR.ROI.HbTotal-nanmean(fNIR.ROI.HbTotal(blIndexStart:blIndexEnd,:),1);
                    end
                    %end
            end
             
        end
    end
    

end

validFields=pf2_base.pf2_getFNIRSfields();

fdataFields=fieldnames(fNIR);  % Copy known fields
for i=1:length(fdataFields)
   memberIdx=ismember(validFields,fdataFields{i});
   if(any(memberIdx)&&~strcmp(fdataFields{i},'time')&&~strcmp(fdataFields{i},'ROI')&&~isfield(outfNIR,fdataFields{i}))
        outfNIR.(validFields{memberIdx})=fNIR.(fdataFields{i});
   end
end

if(isfield(outfNIR,'Aux')&&splitAux)
    if(~isempty(outfNIR.Aux))
        
        if(~isfield(outfNIR.Aux,'flattened'))
            outfNIR.Aux=recursiveAuxFlatten(fNIR.Aux,fNIR.time);
            outfNIR.Aux.flattened=true;
        end

        validTimeFields={'time','t','Time','elapsedTime'};
    
        if(outfNIR.Aux.flattened)
            auxTrimFields=fieldnames(outfNIR.Aux);
    
            for atIdx=1:length(auxTrimFields)
                curVar=outfNIR.Aux.(auxTrimFields{atIdx});
     
                if(istable(curVar))
                    curTableVarNames=curVar.Properties.VariableNames;
                    cur_time_ind=find(~isempty(intersect(validTimeFields,curTableVarNames)));
                    t2trim=curVar{:,cur_time_ind};

                    if(isempty(t2trim)||height(t2trim)==0)
                        outfNIR.Aux.(auxTrimFields{atIdx})=curVar;
                    else
                        if((isnumeric(t2trim)&&isnumeric(startTime))||(isdatetime(t2trim)&&isdatetime(startTime)))
                            minftime=startTime;
                            maxftime=endTime;
                        elseif(isnumeric(t2trim)&&isdatetime(startTime))
                            if(~isfield(fNIR,'t0'))
                                warning('Missing t0');
                                continue;
                            else
                                minftime=startTime-fNIR.t0;
                                maxftime=endTime-fNIR.t0;
                            end
                        elseif(isdatetime(t2trim)&&isnumeric(startTime))
                             if(~isfield(fNIR,'t0'))
                                warning('Missing t0');
                                continue;
                            else
                                minftime=fNIR.t0+duration(0,0,startTime);
                                maxftime=fNIR.t0+duration(0,0,endTime);
                             end
                        else
                            error('pf2:split:mismatchedAuxTime', 'Mismatched data');
                        end
    
                        t2trim_idx=t2trim>=minftime&t2trim<=maxftime;
                        outfNIR.Aux.(auxTrimFields{atIdx})=curVar(t2trim_idx,:);
                    end
                end
            end
        end

   else
       outfNIR.Aux=[]; 
    end
elseif(isfield(outfNIR,'Aux')) % don't split or touch it
    outfNIR.Aux=outfNIR.Aux;
end

if(isfield(outfNIR,'markers')&&~isempty(outfNIR.time))
    if(istable(outfNIR.markers)&&~isempty(outfNIR.markers))
        mTime=outfNIR.markers.Time;
        validIndicies=(mTime<=max(outfNIR.time)&mTime>=min(outfNIR.time));
        outfNIR.markers=outfNIR.markers(validIndicies,:);
    elseif(isfield(outfNIR.markers,'data')&&~isempty(outfNIR.markers.data))
        validIndicies=(outfNIR.markers.data(:,1)<=max(outfNIR.time)&outfNIR.markers.data(:,1)>=min(outfNIR.time))==1;
        outfNIR.markers.data=outfNIR.markers.data(validIndicies,:);
    elseif(isnumeric(outfNIR.markers)&&~isempty(outfNIR.markers))
        validIndicies=(outfNIR.markers(:,1)<=max(outfNIR.time)&outfNIR.markers(:,1)>=min(outfNIR.time))==1;
        outfNIR.markers=outfNIR.markers(validIndicies,:);
    end
end

if(isfield(outfNIR,'ftimeChMask'))
    outfNIR.ftimeChMask=outfNIR.ftimeChMask(indexStart:indexEnd,:);
end

if isfield(outfNIR, 'blocks') && ~isempty(outfNIR.blocks) && ~isempty(outfNIR.time)
    tMin = min(outfNIR.time);
    tMax = max(outfNIR.time);
    keep = arrayfun(@(b) b.startTime <= tMax && b.endTime >= tMin, outfNIR.blocks);
    outfNIR.blocks = outfNIR.blocks(keep);
end
    
    
end

function [outAuxStruct] = recursiveAuxFlatten(aux_in,nir_time,parent_time_in)
    auxFields=fieldnames(aux_in);

    if(nargin<3)
        parent_time_in=[];
    end

    % Attempts to resample any field (and align with fNIRS)
        % criteria:
        %   1) field is same length as fNIR (and greater than 1)
        %       uses fNIR time as reference
        %   2) Aux contains own time field
        %       uses Aux time as reference
        %   3) Aux contains column which is time
        %   4) Aux contains table column t or 'time' which contains time

    auxFieldsSize=nan(size(auxFields,1),2);
    auxFieldHasTime=false(size(auxFields));
    auxFieldIsTable=false(size(auxFields));
    auxFieldIsArray=false(size(auxFields));
    auxFieldIsStruct=false(size(auxFields));
    auxFieldIsEmpty=false(size(auxFields));

    if(isfield(aux_in,'flattened')&&aux_in.flattened)
        alreadyFlattened=true;
    else
        alreadyFlattened=false;
    end



    validTimeFields={'time','t','Time', 'elapsedTime'};

    cur_time_ind=find(~isempty(intersect(validTimeFields,auxFields)));

    if(isempty(cur_time_ind))
        local_time=[];
        localTimeInd=[];
    else
        local_time=aux_in.(validTimeFields{cur_time_ind});
        outAuxStruct.(validTimeFields{cur_time_ind})=local_time;
    end

    szLocalTime=size(local_time);
    szParentTime=size(parent_time_in);
    szNIRTime=size(nir_time);


    % look through each aux field for times
    for f=1:length(auxFields)
        
        curFieldName=auxFields{f};
        curField=aux_in.(curFieldName);

        % Skip metadata fields (used for labeling, not time-series data)
        if ismember(curFieldName, {'varNames', 'unit'})
            continue;
        end

        if(isempty(curField))
            auxFieldIsEmpty(f)=true;
            outAuxStruct.(curFieldName)=curField;
            continue;
        end

        t_aux=[];
        t_ind=[];

        auxFieldIsTable(f)=istable(curField);
        auxFieldIsStruct(f)=isstruct(curField);
        auxFieldIsArray(f)=isnumeric(curField)||islogical(curField)||isduration(curField)||isdatetime(curField);

        if(auxFieldIsTable(f)||auxFieldIsArray(f))
            auxFieldsSize(f,[1:2])=size(curField);
        end
        

        if(auxFieldIsArray(f)&&auxFieldsSize(f,1)>1&&~alreadyFlattened)
            % If the field is an array, we use external time in this order
            %   1) local struct
            %   2) parent struct
            %   3) nir_struct
            
            auxFieldHasTime(f)=false;
            % if time is present in local struct and time matches, use that
            if(~isempty(local_time)&&auxFieldsSize(f,1)==szLocalTime(1))
                 t_aux=local_time;
            % if time is present in parent struct and time matches, use that
            elseif(~isempty(parent_time_in)&&auxFieldsSize(f,1)==szParentTime(1))
                t_aux=parent_time_in;
            % if time is present in nir and time matches, use that, but warn
            elseif(~isempty(nir_time)&&auxFieldsSize(f,1)==szNIRTime(1))
                t_aux=nir_time;
                warning('Non-explicit match for Aux resampling, please use Aux.time variable or ''time'' table column ');
            else % maybe if the first column is constantly incrementing we use that?

                possibleTimeField=all(diff(curField(:,1)>0));
                if(possibleTimeField)
                    t_aux=curField(:,1);
                    auxFieldHasTime(f)=true;
                    warning('Non-explicit match for Aux resampling, please use Aux.time variable or ''time'' table column ');
                else
                    %fprintf('Unable to resample this field!');
                    outAuxStruct.(curFieldName)=['Unable to align this field!'];
                    
                    continue;
                end
            end

            nAuxChan=size(curField,2);
            nDataCols=nAuxChan-auxFieldHasTime(f);

            % Use varNames from parent struct if available
            if isfield(aux_in,'varNames') && iscell(aux_in.varNames) && length(aux_in.varNames)>=nDataCols
                newVarNames=aux_in.varNames(1:nDataCols);
            else
                newVarNames={};
                for nV=1:nDataCols
                    newVarNames{nV}=sprintf('val%i',nV);
                end
            end

            if(auxFieldHasTime(f))
                newVarNames=['time',newVarNames(:)];
                auxDat_rsTable=array2table(curField,'VariableNames',newVarNames);
                outAuxStruct.(curFieldName)=auxDat_rsTable;
            else
                outAuxStruct.(curFieldName)=table(t_aux,'VariableNames',{'time'});
                auxDat_rsTable=array2table(curField,'VariableNames',newVarNames);
                outAuxStruct.(curFieldName)=[outAuxStruct.(curFieldName),auxDat_rsTable];
            end
            
        

        % if it is a table
        elseif(auxFieldIsTable(f)&&auxFieldsSize(f,1)>1)
            
            auxVarNames=curField.Properties.VariableNames;
            timeTableVar=intersect(validTimeFields,curField.Properties.VariableNames);
            

            if(~isempty(timeTableVar))
                t_aux=curField.(timeTableVar{1});
                if(iscell(t_aux)&&~isempty(t_aux))
                    t_aux=t_aux{1};
                end
                
                auxFieldHasTime(f)=true;
                curTimeNames=timeTableVar{1};
                auxVarNames(ismember(auxVarNames,validTimeFields))=[];
            elseif(~isempty(local_time)&&auxFieldsSize(f,1)==szLocalTime(1)&&~alreadyFlattened)
                 t_aux=local_time;
                % if time is present in parent struct and time matches, use that
            elseif(~isempty(parent_time_in)&&auxFieldsSize(f,1)==szParentTime(1)&&~alreadyFlattened)
                t_aux=parent_time_in;
                
            % if time is present in nir and time matches, use that, but warn
            elseif(~isempty(nir_time)&&auxFieldsSize(f,1)==szNIRTime(1)&&~alreadyFlattened)
                t_aux=nir_time;
                
                warning('Non-explicit match for Aux time variable alignment, please use Aux.time variable or ''time'' table column ');
            else % maybe if the first column is constantly incrementing we use that?

                
                possibleTimeField=isnumeric(curField(:,1))&&all(diff(curField(:,1)>0));
                if(possibleTimeField&&~alreadyFlattened)
                    t_aux=curField(:,1);
                    curTimeNames='time';
                    auxFieldHasTime(f)=true;
                    warning('Non-explicit match for Aux time variable alignment, please use Aux.time variable or ''time'' table column ');
                else
                    %fprintf('Unable to resample this field!');
                    if(~alreadyFlattened)
                        outAuxStruct.(curFieldName)=['Unable to resample this field!'];
                    else
                        outAuxStruct.(curFieldName)=curField;
                    end
                    
                    continue;
                end
            end

            

            
            outAuxStruct.(curFieldName)=table(t_aux,'VariableNames',curTimeNames);
            

            

            % run through table variables
            for var=1:length(auxVarNames)
            
                curVarName=auxVarNames{var};
                curVar=curField.(curVarName);

                
                % Count number of columns within each variable
                numericIdx=false(1,size(curVar,2));
                %szNumeric=zeros(1,size(curVar,2));
                for c=1:size(curVar,2)
                    % check if the column is numeric
                    numericIdx(c)=isnumeric(curVar(:,c))||islogical(curVar(:,c));
                    
                    %szNumeric(c)=numericIdx(c).*max(size(curVar(1,c),2));
                end
                tempTbl=curVar(:,numericIdx);

                len=size(tempTbl,1);

                if(~isempty(tempTbl)&&any(len==size(t_aux)))
                    
                    if(istable(tempTbl))
                        rsArr=table2array(tempTbl);
                    else
                        rsArr=tempTbl;
                    end
                   
                    auxDat_resample=rsArr;

                    
                    numCols=length(numericIdx);

                    if(numCols>1)
                        newVarNames=cell(size(numericIdx));
                    
                       for nName=1:length(newVarNames)
                           newVarNames{nName}=sprintf('%s_%i',curVarName,nName);
                        end
                    else
                        newVarNames={curVarName};
                    end
                    

                  

                  
                    auxDat_rsTable=array2table(auxDat_resample,'VariableNames',newVarNames);
                    outAuxStruct.(curFieldName)=[outAuxStruct.(curFieldName),auxDat_rsTable];
                    
                end
            end

    
        elseif(auxFieldIsStruct(f))
            
            struct2unpack=recursiveAuxFlatten(aux_in.(curFieldName),nir_time,local_time);

            fields2assign=fieldnames(struct2unpack);
            for f2=1:length(fields2assign) 
                subFieldName=fields2assign{f2};
                newFieldName=sprintf('%s_%s',curFieldName,subFieldName);
                outAuxStruct.(newFieldName)=struct2unpack.(subFieldName);
            end
            
        else
            %if its not one of these, just dont bother resampling or
            %unpacking
            outAuxStruct.(curFieldName)=curField;
        end
    end


end
