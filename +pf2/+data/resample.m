function [outFNIR, pFit] = resample(fNIR, segmentLength, blLength, opts)
% RESAMPLE Downsample and time-average fNIRS data
%
% Resamples fNIRS data to a lower sampling rate by averaging samples within
% time bins. Useful for reducing data size, matching sampling rates between
% devices, or computing block averages for analysis.
%
% Syntax:
%   outFNIR = pf2.data.resample(fNIR, segmentLength)
%   outFNIR = pf2.data.resample(fNIR, segmentLength, blLength)
%   outFNIR = pf2.data.resample(..., 'Name', Value)
%   [outFNIR, pFit] = pf2.data.resample(...)  % With polynomial fit
%
% Inputs:
%   fNIR              - fNIRS data structure (raw or processed)
%   segmentLength     - Duration of each output sample in seconds (default: 1)
%                       Output sampling rate = 1/segmentLength Hz
%   blLength          - Baseline period length in seconds (optional)
%                       First blLength seconds used for baseline subtraction.
%                       Set to 0 or omit to skip baseline correction.
%   'blfNIR'          - Separate fNIRS struct to use as baseline source
%                       Overrides blLength when provided
%   'centerOnT0'      - Align bins to t=0 reference point (default: false)
%                       If true: bins are [...,-10:0, 0:10, 10:20,...]
%                       If false: bins start at first sample time
%   'centerOnTime'    - Align bins to specific time (overrides centerOnT0)
%   'timeOutMode'     - Output time representation (default: 'start')
%                       'start': Return bin start time
%                       'mid': Return bin midpoint time
%                       'end': Return bin end time
%   'nanRejectionLevel' - Fraction of NaN values to reject bin (default: 0.7)
%                       Bins with >70% NaN values return NaN
%   'specifiedTimepoints' - Resample at specific times instead of regular grid
%   'averageAux'      - Also average auxiliary data (default: false)
%   'flattenAux'      - Flatten auxiliary to single value (default: false)
%   'trimAux'         - Trim auxiliary to match output length (default: false)
%   'polyDegree'      - Polynomial degree for trend fitting (default: 1)
%
% Outputs:
%   outFNIR           - Resampled fNIRS structure with:
%                       All fields downsampled to new rate
%                       .fs updated to 1/segmentLength
%   pFit              - Polynomial fit coefficients (if 2 outputs requested)
%
% Algorithm:
%   1. Create time bins based on segmentLength and alignment options
%   2. For each bin, compute nanmean of all samples in bin
%   3. If baseline specified, subtract baseline mean from each bin
%   4. Reject bins exceeding nanRejectionLevel
%
% Example:
%   % Resample to 0.1 Hz (10-second bins)
%   resampled = pf2.data.resample(data, 10);
%
%   % Resample with 5-second baseline, centered on t0
%   resampled = pf2.data.resample(data, 10, 5, 'centerOnT0', true);
%
%   % Resample at specific timepoints
%   resampled = pf2.data.resample(data, 'specifiedTimepoints', [0 10 20 30]);
%
% See also: pf2.data.split, pf2.data.setT0, pf2.data.concatenate

arguments
    fNIR
    segmentLength (1,1) {mustBeNumeric, mustBePositive} = 1
    blLength {mustBeNumeric} = []
    opts.blfNIR = []
    opts.centerOnT0 (1,1) logical = false
    opts.timeOutMode {mustBeMember(opts.timeOutMode, {'mid','start','end'})} = 'start'
    opts.nanRejectionLevel (1,1) {mustBeNumeric, mustBeNonnegative} = 0.7
    opts.averageAux (1,1) logical = false
    opts.flattenAux (1,1) logical = false
    opts.trimAux (1,1) logical = false
    opts.polyDegree (1,1) {mustBeNumeric, mustBeNonnegative} = 1
    opts.centerOnTime {mustBeNumeric} = NaN
    opts.specifiedTimepoints {mustBeNumeric} = []
end

segLength=segmentLength; % How long is each segment, ie: 1 sample
blfNIR=opts.blfNIR; % Separate baseline source struct/array (mutated as a local below)
centerOnT0=opts.centerOnT0; % should the resample include t=0 as the start point
centerOnTime=opts.centerOnTime;
specifiedTimepoints = opts.specifiedTimepoints;

if(centerOnT0)
    centerOnTime=0;
end
if(isempty(centerOnTime))
    centerOnTime=nan;
end

timeOutMode=opts.timeOutMode; % should time include or center on a point (ex: t=1 := t[0.051...1.4999]
nanRejectionLevel=opts.nanRejectionLevel; % number of NaNs in segment to entirely reject it
averageAux=opts.averageAux; % Also average/ resample the Aux channels
flattenAux=opts.flattenAux; % Unroll nested Aux data into tables within the Aux struct, also map times to non-time columns
trimAux=opts.trimAux; % Clear all Aux samples before and after fNIRS time series
polyDegree=opts.polyDegree; % degree for polyfit


if(~isstruct(fNIR))
    temp=fNIR;
    fNIR=[];
    fNIR.raw=temp;
    clear temp;
    
    fNIR.time=fNIR.raw(:,1);
end

if(~isempty(blfNIR)&&~isstruct(blfNIR)&&isnumeric(blfNIR))
    temp=blfNIR;
    blfNIR=[];
    blfNIR.raw=temp;
    clear temp;
    
    blfNIR.time=blfNIR.raw(:,1);
end

if(~isfield(fNIR,'time')&&isfield(fNIR,'raw'))
    fNIR.time=fNIR.raw(:,1);
end

fNIR.time=round(fNIR.time,5);

fTime=fNIR.time;

if(~isstruct(blfNIR)&&~isempty(blLength)&&blLength>0)
    % if given a specific baseline length (and no struct, create baseline
    % from times given)
    blfNIR=getFNIRS(fNIR,min(fNIR.time),min(fNIR.time)+blLength); 
elseif(isstruct(blfNIR))
    % if using a baseline struct
    if(~isempty(blfNIR.time)&&~any(isnan(blfNIR.time))&&isfield(blfNIR,'fs'))
        %if time is provided, use all of provided time
        blLength=max(blfNIR.time)-min(blfNIR.time)+1/blfNIR.fs; %Baseline length in time
    elseif(~isempty(blLength)&&~isfield(blfNIR,'empty')&&blLength==0&&~isempty(blfNIR)&&~any(isnan(blfNIR.time))&&isfield(blfNIR,'fs'))
        % else estimate from sampling rate
        blLength=1/blfNIR.fs;
    else
       warning('Entire Baseline is invalid');
       blLength=nan;
    end
elseif(blLength==0)
    blLength=[];
end

if(nargout>1) %provide poly fit only if two arguments are present
    getPolyAvg=true;
elseif(nargout<=1)
    getPolyAvg=false;
end

if(~isfield(fNIR,'HbR')&&isfield(fNIR,'raw'))
    % out of principle we don't resample the raw data
    error('pf2:resample:rawNotSupported', 'Raw data averaging not supported');
elseif(~isfield(fNIR,'HbR')&&~isfield(fNIR,'raw'))
    warning('No fNIRS data');
    outFNIR=fNIR;
    pFit=[];
    return;
else
    numCh=size(fNIR.HbR,2); 
end

if(isnan(centerOnTime))  % foces time blocks to start from t=0 or if undefined, just start from where they started from
    centerOnTime=min(fTime);
end


if ~isempty(specifiedTimepoints)
    [fTimeInd, timeSeries] = getTimeIdxSpecified(fNIR.time, specifiedTimepoints);
    segLength = mean(diff(specifiedTimepoints)); % Approximate segLength for further calculations
else
    [fTimeInd, timeSeries] = getTimeIdx(fNIR.time, segLength, centerOnTime);
end

numSegs=length(timeSeries);

if isfield(fNIR,'ROI') && isstruct(fNIR.ROI) && isfield(fNIR.ROI,'HbR') && ~isempty(fNIR.ROI.HbR)
    calcROI=true;
    numROI=size(fNIR.ROI.HbR,2);
else
    calcROI=false;
    numROI=0;
end


if(isfield(fNIR,'Aux'))
    if(~averageAux)
        outFNIR.Aux=fNIR.Aux;
    else
        
        outFNIR.Aux=struct();
    end
else
    averageAux=false;
end


validCh=1:numCh;
if(calcROI)
    validCh_roi=1:numROI;
end

if(blLength>0) % if baseline is present
    bioMlist={'HbO','HbR','HbDiff','HbTotal','CBSI'};

    for b = 1:length(bioMlist)
        curB=bioMlist{b};

        if(~isfield(blfNIR,curB))
            continue;
        end

        fB=blfNIR.(curB);
   
        blNanCheck=sum(isnan(fB),1)/size(fB,1)<nanRejectionLevel; %calculate percentage of invalid values in baseline

        blRejectedCount=sum(~blNanCheck);
        
        if(blRejectedCount>1)
            warning('pf2:resample:invalidBaseline', ...
                'Baseline Period in %i channels was invalid', blRejectedCount);
        end
        
        validCh=find(blNanCheck==1);

        blfNIR.(curB)=mean(fB,1,'omitnan');
        blfNIR.(curB)(~blNanCheck)=nan;

        if(isempty(blfNIR.(curB)))
            blfNIR.(curB)=nan;
        end

        % Per-iteration ROI guard. Using a loop-wide calcROI mutation here
        % latched false on the first missing ROI biomarker and silently
        % skipped ROI baseline subtraction for every subsequent biomarker
        % in the second loop. Scope the "skip" to this iteration only.
        roiOK = calcROI;
        if(roiOK)

            if isfield(blfNIR,'ROI') && isstruct(blfNIR.ROI) && isfield(blfNIR.ROI, curB)
                fB=blfNIR.ROI.(curB);
            else
                warning('ROI mismatch: ROI is not defined in baseline file');
                roiOK=false;
            end

            if(roiOK && size(fB,2)~=numROI)
                warning('ROI mismatch: ROI as defined in baseline not present in main fNIRS segment, calculations not performed');
                roiOK=false;
            end
        end
        if(roiOK)

            blNanCheck_roi=sum(isnan(fB),1)/size(fB,1)<nanRejectionLevel; %calculate percentage of invalid values in baseline

            blRejectedCount_roi=sum(~blNanCheck_roi);
            if(blRejectedCount_roi>1)
                warning('pf2:resample:invalidBaseline', 'ROI Baseline Period in %i channels was invalid',blRejectedCount_roi);
            end
            validCh_roi=find(blNanCheck_roi==1);
            
            blfNIR.ROI.(curB)=mean(fB,1,'omitnan');
            blfNIR.ROI.(curB)(~blNanCheck_roi)=nan;
    
            if(isempty(blfNIR.ROI.(curB)))
                blfNIR.ROI.(curB)=nan;
            end
        end
    end  
else
    validCh=1:numCh;
    if(calcROI)
       validCh_roi=1:numROI;
    else
        numROI=0;
    end
end


if(strcmp(timeOutMode,'start')) %default
    timeOutModeMid=false;
    timeOutModeEnd=false;
elseif(strcmp(timeOutMode,'end'))
    timeOutModeMid=false;
    timeOutModeEnd=true;
else %Return midpoint
    timeOutModeMid=true;
    timeOutModeEnd=false;
end

if(timeOutModeMid)
    times_start=timeSeries-segLength/2;
    times_end=timeSeries+segLength/2-(1e-10);
elseif(timeOutModeEnd)
    times_start=timeSeries-segLength+(1e-10);
    times_end=timeSeries;
else
    times_start=timeSeries;
    times_end=timeSeries+segLength-1e-10;
end

if(calcROI)
    outFNIR.ROI.info=fNIR.ROI.info;
end

bioMlist={'raw','HbO','HbR','HbDiff','HbTotal','CBSI'};

for b = 1:length(bioMlist)
    curB=bioMlist{b};

    if(~isfield(fNIR,curB))
        continue;
    end

    isRaw=strcmpi(curB,'raw');
    fB=fNIR.(curB);

    

    numCh=size(fB,2);

    fB_resample=resample_internal(fB,fTimeInd,numCh,numSegs,nanRejectionLevel);

    if(~isempty(blLength)&&blLength>0&&~isRaw)
        outFNIR.(curB)=fB_resample-repmat(blfNIR.(curB),[numSegs,1]);
    elseif(~isempty(blLength)&&isnan(blLength)&&~isRaw)
        outFNIR.(curB)=nan([numSegs,numCh]);
    else
        outFNIR.(curB)=fB_resample;
    end


    if(getPolyAvg)
        pFit.(curB)=nan([numSegs,numCh,polyDegree+1]);
        bioFitVal=sprintf('%s_val',curB);
        pFit.(bioFitVal)=nan([numSegs,numCh]);
        
        
        for chIdx=1:length(validCh)
            ch=validCh(chIdx);
            validIdx=~isnan(fB(:,ch));
            for segIdx=1:numSegs
                tSeg=validIdx&fTimeInd==segIdx;
                tSegTimeRem=fTime(tSeg)-times_start(segIdx);
                
                pFit.(bioFitVal)(segIdx,ch,1:polyDegree+1)=mpolyfit(tSegTimeRem,fB(tSeg,ch),polyDegree);
                pFit.(curB)(segIdx,ch)=polyval(reshape(pFit.(bioFitVal)(segIdx,ch,:),[polyDegree+1,1,1]),times_end(segIdx)-segLength/2);
            end
        end

        if(~isempty(blLength)&&blLength>0&&~isRaw)
            pFit.(curB)=pFit.(curB)-repmat(blfNIR.(curB),[numSegs,1]);
        elseif(~isempty(blLength)&&isnan(blLength)&&~isRaw)
            pFit.(curB)=nan([numSegs,numCh]);
        end
    end

    if(calcROI&&~isRaw)
        fB=fNIR.ROI.(curB);

        fB_resample=resample_internal(fB,fTimeInd,numROI,numSegs,nanRejectionLevel);

        % Only subtract a ROI baseline mean for this biomarker if the
        % first loop successfully reduced blfNIR.ROI.(curB) to a 1xnROI
        % row. When it didn't (missing field, size mismatch, etc.) the
        % field is either absent or still holds the raw [T_bl x nROI]
        % split slice — subtracting that would produce wrong-sized output.
        hasROIBaseline = isfield(blfNIR,'ROI') && isstruct(blfNIR.ROI) && ...
            isfield(blfNIR.ROI, curB) && size(blfNIR.ROI.(curB), 1) == 1;

        if(~isempty(blLength)&&blLength>0&&hasROIBaseline)
            outFNIR.ROI.(curB)=fB_resample-repmat(blfNIR.ROI.(curB),[numSegs,1]);
        elseif(~isempty(blLength)&&isnan(blLength))
            outFNIR.ROI.(curB)=nan([numSegs,numROI]);
        else
            outFNIR.ROI.(curB)=fB_resample;
        end

        if(getPolyAvg)
            pFit.ROI.(curB)=nan([numSegs,numROI,polyDegree+1]);
            bioFitVal=sprintf('%s_val',curB);
            pFit.ROI.(bioFitVal)=nan([numSegs,numROI]);
            
            
            for chIdx=1:length(validCh_roi)
                ch=validCh_roi(chIdx);
                validIdx=~isnan(fB(:,ch));
                for segIdx=1:numSegs
                    tSeg=validIdx&fTimeInd==segIdx;
                    tSegTimeRem=fTime(tSeg)-times_start(segIdx);

                    pFit.ROI.(bioFitVal)(segIdx,ch,1:polyDegree+1)=mpolyfit(tSegTimeRem,fB(tSeg,ch),polyDegree);
                    pFit.ROI.(curB)(segIdx,ch)=polyval(reshape(pFit.ROI.(bioFitVal)(segIdx,ch,:),[polyDegree+1,1,1]),times_end(segIdx)-segLength/2);
                end
            end

            if(~isempty(blLength)&&blLength>0&&hasROIBaseline)
                pFit.ROI.(curB)=pFit.ROI.(curB)-repmat(blfNIR.ROI.(curB),[numSegs,1]);
            elseif(~isempty(blLength)&&isnan(blLength))
                pFit.ROI.(curB)=nan([numSegs,numROI]);
            end
        end
    end
end

if(isfield(fNIR,'Aux')&&~isempty(fNIR.Aux)&&length(fieldnames(fNIR.Aux))>1)
    if(averageAux)
        % Attempts to resample any field (and align with fNIRS)
            % criteria:
            %   1) field is same length as fNIR (and greater than 1)
            %       uses fNIR time as reference
            %   2) Aux contains own time field
            %       uses Aux time as reference
            %   3) Aux contains column which is time
            %   4) Aux contains table column t or 'time' which contains time
    
        outFNIR.Aux=recursiveAuxResample(fNIR.Aux,flattenAux,segLength,centerOnTime,fNIR.time,fTimeInd,nanRejectionLevel);

        if(isfield(fNIR.Aux,'flattened'))
            outFNIR.Aux.flattened=flattenAux||fNIR.Aux.flattened;
        else
            outFNIR.Aux.flattened=flattenAux;
        end
    elseif(flattenAux) %flatten without averaging
        outFNIR.Aux=recursiveAuxFlatten(fNIR.Aux,fNIR.time);
        if(isfield(fNIR.Aux,'flattened'))
            outFNIR.Aux.flattened=flattenAux||fNIR.Aux.flattened;
        else
            outFNIR.Aux.flattened=flattenAux;
        end
    else
        outFNIR.Aux=fNIR.Aux;
    end

    if(trimAux)
        validTimeFields={'time','t','Time'};
    
        if(outFNIR.Aux.flattened)
            auxTrimFields=fieldnames(outFNIR.Aux);
    
            for atIdx=1:length(auxTrimFields)
                curVar=outFNIR.Aux.(auxTrimFields{atIdx});
     
                if(istable(curVar))
                    curTableVarNames=curVar.Properties.VariableNames;
                    cur_time_ind=find(ismember(validTimeFields,curTableVarNames),1);
                    t2trim=curVar{:,cur_time_ind};
                    minftime=times_start(1);
                    maxftime=times_end(end);
                    t2trim_idx=t2trim>minftime&t2trim<maxftime;
                    outFNIR.Aux.(auxTrimFields{atIdx})=curVar(t2trim_idx,:);
                end
            end
            
        else
             error('pf2:resample:trimRequiresFlatten', 'Trimming requires Aux series to be flattened first!');
        end
    
    end
end


validFields=pf2_base.pf2_getFNIRSfields();
fdataFields=fieldnames(fNIR);  % Copy known fields
for fieldIdx=1:length(fdataFields)
   memberIdx=ismember(validFields,fdataFields{fieldIdx});
   if(any(memberIdx)&&~strcmp(fdataFields{fieldIdx},'time')...
           &&~strcmp(fdataFields{fieldIdx},'fs')&&~strcmp(fdataFields{fieldIdx},'ROI')&&~strcmp(fdataFields{fieldIdx},'Aux'))
        outFNIR.(validFields{memberIdx})=fNIR.(fdataFields{fieldIdx});
   end
end

outFNIR.segmentTimes=[times_start,timeSeries,times_end];

if(~isempty(outFNIR.segmentTimes))
    if(strcmp(timeOutMode,'start'))
        outFNIR.time=outFNIR.segmentTimes(:,1); %returns effective "sample point" as startpoint of segmentTimes
        if(isfield(outFNIR,'t0')&&isdatetime(outFNIR.t0))
            outFNIR.datetime=outFNIR.t0+(duration(0,0,outFNIR.segmentTimes(:,1)));
        end
    elseif(strcmp(timeOutMode,'end'))
        outFNIR.time=outFNIR.segmentTimes(:,2); %returns effective "sample point" as endpoint of segmentTimes
        if(isfield(outFNIR,'t0')&&isdatetime(outFNIR.t0))
            outFNIR.datetime=outFNIR.t0+(duration(0,0,outFNIR.segmentTimes(:,1)));
        end
    else %Return midpoint
        outFNIR.time=timeSeries; %mean(outFNIR.segmentTimes,2); %returns effective "sample point" as midpoint of segmentTimes
        if(isfield(outFNIR,'t0')&&isdatetime(outFNIR.t0))
            outFNIR.datetime=outFNIR.t0+(duration(0,0,outFNIR.time));
        end
        % should match timeSeries variable
    end
else
   outFNIR.time=[]; 
end

if(isempty(outFNIR.time))
    outFNIR.time=nan;
    outFNIR.empty=1;
end
    

outFNIR.fs=1/segLength; %new "effective sampling frequency

if(getPolyAvg) % returns a time X channel X coefficient array
    % Merge metadata from outFNIR into pFit (preserving polynomial data from loop)
    outFields = fieldnames(outFNIR);
    for fi = 1:length(outFields)
        fn = outFields{fi};
        if ~isfield(pFit, fn)
            pFit.(fn) = outFNIR.(fn);
        end
    end
else
    pFit=[];
end

end

function [outAuxStruct] = recursiveAuxResample(aux_in,flattenAux,segLength,centerOnTime,nir_time,fTimeInd,nanRejectionLevel,parent_time_in,parentTimeInd)
    auxFields=fieldnames(aux_in);

    if(nargin<8)
        parent_time_in=[];
        parentTimeInd=[];
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



    validTimeFields={'time','t','Time'};

    cur_time_ind=find(ismember(validTimeFields,auxFields),1);

    if(isempty(cur_time_ind))
        local_time=[];
        localTimeInd=[];
    else
        local_time=aux_in.(validTimeFields{cur_time_ind});
        [localTimeInd,localTime_resample]=getTimeIdx(local_time,segLength,centerOnTime);
        outAuxStruct.(validTimeFields{cur_time_ind})=localTime_resample;
    end

    szLocalTime=size(local_time);
    szParentTime=size(parent_time_in);
    szNIRTime=size(nir_time);


    % look through each aux field for timeSeries
    for f=1:length(auxFields)

        curFieldName=auxFields{f};
        curField=aux_in.(curFieldName);

        % Skip metadata fields (used for labeling, not time-series data)
        if ismember(curFieldName, {'varNames', 'unit'}) || endsWith(curFieldName, '_unit')
            continue;
        end

        if(isempty(curField))
            warning('pf2:resample:emptyAux', ...
                'Unable to average signal .Aux.%s, no data present', curFieldName);
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

            isDateTimeType=isdatetime(curField);
            isDurationType=isduration(curField);

            if(isDateTimeType)
                t0=datetime(2020,1,1);
                curField=seconds(curField-t0);
            elseif(isDurationType)
                curField=seconds(curField);
            end
            
            auxFieldHasTime(f)=false;
            % if time is present in local struct and time matches, use that
            if(~isempty(local_time)&&auxFieldsSize(f,1)==szLocalTime(1))
                 t_aux=local_time;
                 t_ind=localTimeInd;
            % if time is present in parent struct and time matches, use that
            elseif(~isempty(parent_time_in)&&auxFieldsSize(f,1)==szParentTime(1))
                t_aux=parent_time_in;
                t_ind=parentTimeInd;
            % if time is present in nir and time matches, use that, but warn
            elseif(~isempty(nir_time)&&auxFieldsSize(f,1)==szNIRTime(1))
                t_aux=nir_time;
                t_ind=fTimeInd;
                warning('Non-explicit match for Aux resampling, please use Aux.time variable or ''time'' table column ');
            else % maybe if the first column is constantly incrementing we use that?

                possibleTimeField=all(diff(curField(:,1))>0);
                if(possibleTimeField)
                    t_aux=curField(:,1);
                    auxFieldHasTime(f)=true;
                    warning('Non-explicit match for Aux resampling, please use Aux.time variable or ''time'' table column ');
                else
                    outAuxStruct.(curFieldName)=['Unable to resample this field!'];

                    continue;
                end
            end

            nAuxChan=size(curField,2);
            

            %create t_ind if missing, always compute t_aux_resample for flattening
            [t_ind_computed, t_aux_resample] = getTimeIdx(t_aux, segLength, centerOnTime);
            if(isempty(t_ind))
                t_ind = t_ind_computed;
            end


            numSegs_aux=max(t_ind);

            auxDat=curField(:);
            auxDat_resample=resample_internal(auxDat,t_ind,nAuxChan,numSegs_aux,nanRejectionLevel);

            if(auxFieldHasTime(f))
                auxDat_resample(:,1)=t_aux_resample;
            end

            if(isDateTimeType)
                auxDat_resample=duration(0,0,auxDat_resample)+t0;
                auxDat_resample.Format='yyyy-MM-dd hh:mm:ss.SSS';
            elseif(isDurationType)
                auxDat_resample=duration(0,0,auxDat_resample);
            end

            if(flattenAux)
                nDataCols=nAuxChan-auxFieldHasTime(f);
                % Use varNames from parent struct if available
                if isfield(aux_in,'varNames') && iscell(aux_in.varNames) && length(aux_in.varNames)==nDataCols
                    newVarNames=aux_in.varNames(1:nDataCols);
                else
                    newVarNames={};
                    for nV=1:nDataCols
                        newVarNames{nV}=sprintf('val%i',nV);
                    end
                end

                % Guard: ensure name count matches column count
                nResampleCols=size(auxDat_resample,2);
                if(auxFieldHasTime(f))
                    expectedCols=1+numel(newVarNames);
                    if nResampleCols~=expectedCols
                        newVarNames={};
                        for nV=1:nResampleCols-1
                            newVarNames{nV}=sprintf('val%i',nV);
                        end
                    end
                    newVarNames=['time',newVarNames(:)];
                    auxDat_rsTable=array2table(auxDat_resample,'VariableNames',newVarNames);
                    outAuxStruct.(curFieldName)=auxDat_rsTable;
                else
                    if numel(newVarNames)~=nResampleCols
                        newVarNames={};
                        for nV=1:nResampleCols
                            newVarNames{nV}=sprintf('val%i',nV);
                        end
                    end
                    outAuxStruct.(curFieldName)=array2table([t_aux_resample, auxDat_resample], ...
                        'VariableNames', [{'time'}, newVarNames(:)']);
                end
            else
                outAuxStruct.(curFieldName)=auxDat_resample;
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
                t_ind=[];
                auxFieldHasTime(f)=true;
                curTimeNames=auxVarNames(ismember(auxVarNames,validTimeFields));
                auxVarNames(ismember(auxVarNames,validTimeFields))=[];
            elseif(~isempty(local_time)&&auxFieldsSize(f,1)==szLocalTime(1)&&~alreadyFlattened)
                 t_aux=local_time;
                 t_ind=localTimeInd;
            % if time is present in parent struct and time matches, use that
            elseif(~isempty(parent_time_in)&&auxFieldsSize(f,1)==szParentTime(1)&&~alreadyFlattened)
                t_aux=parent_time_in;
                t_ind=parentTimeInd;
            % if time is present in nir and time matches, use that, but warn
            elseif(~isempty(nir_time)&&auxFieldsSize(f,1)==szNIRTime(1)&&~alreadyFlattened)
                t_aux=nir_time;
                t_ind=fTimeInd;
                warning('Non-explicit match for Aux resampling, please use Aux.time variable or ''time'' table column ');
            else % maybe if the first column is constantly incrementing we use that?

                
                possibleTimeField=isnumeric(curField(:,1))&&all(diff(curField(:,1))>0);
                if(possibleTimeField&&~alreadyFlattened)
                    t_aux=curField(:,1);
                    auxFieldHasTime(f)=true;
                    warning('Non-explicit match for Aux resampling, please use Aux.time variable or ''time'' table column ');
                else
                    if(~alreadyFlattened)
                        outAuxStruct.(curFieldName)=['Unable to resample this field!'];
                    else
                        outAuxStruct.(curFieldName)=curField;
                    end

                    continue;
                end
            end

            %create t_ind if missing, always compute t_aux_resample for flattening
            [t_ind_computed, t_aux_resample] = getTimeIdx(t_aux, segLength, centerOnTime);
            if(isempty(t_ind))
                t_ind = t_ind_computed;
            end

            if(auxFieldHasTime(f)||flattenAux)
                if(exist('curTimeNames','var')&&~isempty(curTimeNames))
                    outAuxStruct.(curFieldName)=table(t_aux_resample,'VariableNames',curTimeNames);
                else
                    outAuxStruct.(curFieldName)=table(t_aux_resample,'VariableNames',{'time'});
                end
            else
                outAuxStruct.(curFieldName)=table();
            end
    
            n_aux_time=length(t_ind);
            numSegs_aux=max(t_ind);


            

            % run through table variables
            for var=1:length(auxVarNames)
            
                curVarName=auxVarNames{var};
                curVar=curField.(curVarName);

                %disp(curVarName)

                %datetime conversion/resample
                isDateTimeType=isdatetime(curVar);
                isDurationType=isduration(curVar);
    
                if(isDateTimeType)
                    t0=datetime(2020,1,1);
                    curVar=seconds(curVar-t0);
                elseif(isDurationType)
                    curVar=seconds(curVar);
                end

                % Count number of columns within each variable
                numericIdx=false(1,size(curVar,2));
                dateTimeIdx=false(1,size(curVar,2));
                durationIdx=false(1,size(curVar,2));
                %szNumeric=zeros(1,size(curVar,2));
                for c=1:size(curVar,2)
                    % check if the column is numeric
                    numericIdx(c)=isnumeric(curVar(:,c))||islogical(curVar(:,c));
                    
                    %szNumeric(c)=numericIdx(c).*max(size(curVar(1,c),2));
                end
                tempTbl=curVar(:,numericIdx);

                len=size(tempTbl,1);

                if(~isempty(tempTbl)&&any(len==(n_aux_time)))
                    
                    if(istable(tempTbl))
                        rsArr=table2array(tempTbl);
                    else
                        rsArr=tempTbl;
                    end
                    nAuxChan_col=size(rsArr,2);
                    

                    auxDat=rsArr(:);
                    auxDat_resample=resample_internal(auxDat,t_ind,nAuxChan_col,numSegs_aux,nanRejectionLevel);

                    if(flattenAux)
                        numCols=sum(numericIdx);

                        if(numCols>1)
                            newVarNames=cell(1,numCols);

                           for nName=1:numCols
                               newVarNames{nName}=sprintf('%s_%i',curVarName,nName);
                            end
                        else
                            newVarNames={curVarName};
                        end
                    end

                    if(isDateTimeType)
                        auxDat_resample=duration(0,0,auxDat_resample)+t0;
                        auxDat_resample.Format='yyyy-MM-dd hh:mm:ss.SSS';
                    elseif(isDurationType)
                        auxDat_resample=duration(0,0,auxDat_resample);
                    end

                    if(flattenAux)
                        auxDat_rsTable=array2table(auxDat_resample,'VariableNames',newVarNames);
                        outAuxStruct.(curFieldName)=[outAuxStruct.(curFieldName),auxDat_rsTable];
                    else
                        outAuxStruct.(curFieldName).(curVarName)=auxDat_resample;
                    end
                end
            end

    
        elseif(auxFieldIsStruct(f))
            if(~flattenAux)
                outAuxStruct.(curFieldName)=recursiveAuxResample(aux_in.(curFieldName),false,segLength,centerOnTime,nir_time,fTimeInd,nanRejectionLevel,local_time,localTimeInd);
            else
                struct2unpack=recursiveAuxResample(aux_in.(curFieldName),true,segLength,centerOnTime,nir_time,fTimeInd,nanRejectionLevel,local_time,localTimeInd);

                fields2assign=fieldnames(struct2unpack);
                for f2=1:length(fields2assign) 
                    subFieldName=fields2assign{f2};
                    newFieldName=sprintf('%s_%s',curFieldName,subFieldName);
                    outAuxStruct.(newFieldName)=struct2unpack.(subFieldName);
                end
            end
        else
            %if its not one of these, just dont bother resampling
            outAuxStruct.(curFieldName)=curField;
        end
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



    validTimeFields={'time','t','Time'};

    cur_time_ind=find(ismember(validTimeFields,auxFields),1);

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


    % look through each aux field for timeSeries
    for f=1:length(auxFields)
        
        curFieldName=auxFields{f};
        curField=aux_in.(curFieldName);

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

                possibleTimeField=all(diff(curField(:,1))>0);
                if(possibleTimeField)
                    t_aux=curField(:,1);
                    auxFieldHasTime(f)=true;
                    warning('Non-explicit match for Aux resampling, please use Aux.time variable or ''time'' table column ');
                else
                    outAuxStruct.(curFieldName)=['Unable to align this field!'];
                    
                    continue;
                end
            end

            nAuxChan=size(curField,2);
          

            newVarNames={};
            for nV=1:(nAuxChan-auxFieldHasTime(f))
                newVarNames{nV}=sprintf('val%i',nV);
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
                curTimeNames=auxVarNames(ismember(auxVarNames,validTimeFields));
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

                
                possibleTimeField=isnumeric(curField(:,1))&&all(diff(curField(:,1))>0);
                if(possibleTimeField&&~alreadyFlattened)
                    t_aux=curField(:,1);
                    auxFieldHasTime(f)=true;
                    warning('Non-explicit match for Aux time variable alignment, please use Aux.time variable or ''time'' table column ');
                else
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


                    numCols=sum(numericIdx);

                    if(numCols>1)
                        newVarNames=cell(1,numCols);

                       for nName=1:numCols
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

function [fTimeInd,timeSeries]=getTimeIdx(times_in,segLength,centerTime)
    % Returns the time indicies for a time series times_in
    % sampled by segmentLength and "centered" with a point at centerTime
        % ie: the time series includes the point centerTime, (or would if
        % samples around that time were collected

    if(any(diff(times_in)<0))
        error('pf2:resample:timeNotIncreasing', 'Time series should be increasing in order to resample!');
    end


 
    t1=times_in(1);

    times_in=times_in(:);

    if(nargin<3) % just use min time
        centerTime=t1;
    end

    minSegTime=centerTime+floor((t1-centerTime)/segLength)*segLength;
    % minimum SegTime is the first value that meets the criteria:
    %   t0_rs = centerTime+segLength*N  (where N is some integer)
    %   and t0_sample >= t0_rs  but t0_sample < t0_rs + segLength

    % 1e-10 epsilon prevents floating-point bin-boundary misassignment
    % where floor returns n-1 instead of n for values at exact boundaries
    fTimeInd=[floor((times_in-minSegTime)/segLength+1+1e-10)];
    % fTimeInd(end) is the highest value here, faster than max()
    
    maxSegTime=minSegTime+(fTimeInd(end)-1)*segLength;


    timeSeries=[minSegTime:segLength:maxSegTime]';

    
end

function [rsData] = resample_internal(rsData_in,fTimeInd,numCh,numSegs,nanRejectionLevel)
    % resamples data according to the values in fTimeInd(sample indicies)
    % numCh defines the original number of channels
    
    % nanRejectionLevel defines how many nans are allowed before rejecting
    % the segment

        % variable names and sizes
        %   fTimeInd: t x 1
        %   rsData_in: t x N
        %   fTimeInd_numCh t*N x 1
        %   fB_count: s*N x 1
        %   rsData: s x N
    
    nTime=length(fTimeInd);
    fTimeInd_numCh=repmat(fTimeInd,[numCh,1]);
    fTimeInd_numCh=fTimeInd_numCh+numSegs*repelem((0:numCh-1)',nTime,1);

    flat = rsData_in(:);
    nanMask = isnan(flat);
    sz = [numCh * numSegs, 1];

try
    fB_isNA=accumarray(fTimeInd_numCh, double(nanMask), sz);
catch
    rsData=[];
    return;
end
    fB_count=accumarray(fTimeInd_numCh, ones(size(fTimeInd_numCh)), sz);

    fB_nanCheck= reshape(fB_isNA./fB_count,[numSegs,numCh])<=nanRejectionLevel;

    % Vectorized nanmean: sum non-NaN values, divide by valid count.
    % Avoids 1-per-bin function calls to nanmean/mean/parseFlag.
    flat(nanMask) = 0;
    fB_sum = accumarray(fTimeInd_numCh, flat, sz);
    fB_validCount = fB_count - fB_isNA;
    fB_validCount(fB_validCount == 0) = NaN;
    rsData = reshape(fB_sum ./ fB_validCount, [numSegs, numCh]);

    rsData(~fB_nanCheck)=NaN;

end

function [fTimeInd, timeSeries] = getTimeIdxSpecified(times_in, specifiedTimepoints)
    times_in = times_in(:);
    specifiedTimepoints = specifiedTimepoints(:);
    
    fTimeInd = interp1(specifiedTimepoints, 1:length(specifiedTimepoints), times_in, 'nearest', 'extrap');
    timeSeries = specifiedTimepoints;
end


function [c,R2] = mpolyfit(x,y,n) 
% Fits polynomial n to x and y data
if(size(x,1)==1&&size(x,2)>1)
    x=x';
    y=y';
end

if(size(y,1)~=size(x,1))
   error('pf2:resample:xySizeMismatch', 'Size of x and y matricies must be the same');
end
    m = size(x,2); % number of polynomials to fit
    c = zeros(n+1,m); 
    r = zeros(size(y)); 
    for k = 1:m 
        M = repmat(x(:,k),1,n+1); 
        M = bsxfun(@power,M,0:n); 
        c(:,k) = M\y(:,k); 
        r(:,k) = M*c(:,k)-y(:,k);  %calculate residuals
    end 
    sserr = sum(r.^2); 
    sstot = sum(bsxfun(@minus,y,mean(y)).^2); 
    R2 = 1 - sserr./sstot;
    c=fliplr(c')';
    R2=fliplr(R2')';
end