function outFNIR=setT0(fnirStruct, t0time)
% SETT0 Shift time alignment of fNIRS data to a new reference point
%
% Adjusts the time vector and related temporal fields in an fNIRS struct
% so that the specified time point becomes the new t0 (time zero). This is
% useful for aligning data to stimulus onset, baseline periods, or for
% synchronizing multiple datasets.
%
% Syntax:
%   outFNIR = pf2.data.setT0(fnirStruct, t0time)
%
% Inputs:
%   fnirStruct - fNIRS data structure containing time field [struct]
%                Must contain at least a 'time' field. May also contain
%                't0', 'datetime', 'markers', and 'Aux' fields which will
%                all be adjusted accordingly.
%   t0time     - New time reference point [double | duration | datetime]
%                If numeric: time offset in seconds to subtract from time
%                If duration: converted to seconds and subtracted
%                If datetime: requires fnirStruct to have 't0' or 'datetime'
%                field for proper alignment calculation
%
% Outputs:
%   outFNIR - Modified fNIRS struct with shifted time values [struct]
%             The 'time' field will be adjusted so that t0time corresponds
%             to time=0. Marker times and Aux data times are also shifted.
%
% Example:
%   % Shift time so that 10 seconds becomes the new t0
%   data = pf2.import.sampleData.fNIR2000();
%   shiftedData = pf2.data.setT0(data, 10);
%   fprintf('New time range: %.1f to %.1f\n', min(shiftedData.time), max(shiftedData.time));
%
%   % Align to a specific datetime
%   data.t0 = datetime('now');
%   alignedData = pf2.data.setT0(data, datetime('now') + seconds(5));
%
% Notes:
%   - All time-dependent fields are updated: time, markers, Aux subfields
%   - If datetime field exists, t0 is recalculated from datetime
%   - Marker times in column 1 are shifted by the same offset
%
% See also: pf2.data.split, pf2.data.getMarkers, pf2.data.resample

% Inputs are checked with pf2_base.args rather than an arguments block so
% the function also runs under GNU Octave.
fnirStruct = pf2_base.args.check(fnirStruct, '1,1', 'struct', {}, 'Invalid argument at position 1.');
t0time = pf2_base.args.check(t0time, '', '', {@(v) mustBeA(v, {'numeric', 'duration', 'datetime'})}, 'Invalid argument at position 2.');

outFNIR=fnirStruct;



hasDatetime = isfield(outFNIR,'datetime');
hasT0 = isfield(outFNIR,'t0');

if(isduration(t0time))
    tDiff=seconds(t0time);
elseif(isdatetime(t0time))
    if(hasT0)
        outFNIR.t0=t0time;
        % if new time is earlier, this should be negative
        tDiff=seconds(t0time-fnirStruct.t0);
    elseif(hasDatetime)
        % if datetime field is available, use the datetime to subtract
        if(all(size(outFNIR.time)==size(outFNIR.datetime)))
            
            fnirStruct.t0 = outFNIR.datetime(1)-duration(0,0,outFNIR.time(1));
            % if new t0 is before the time of 
            outFNIR.t0 = t0time;
            
            tDiff=seconds(t0time-fnirStruct.t0);
            
        else
            error('pf2:setT0:datetimeSizeMismatch', 'All datetimes must be the same size as times');
        end
    else
        error('pf2:setT0:noDatetime', 't0 cannot be set as a datetime if fnirs struct does not have datetime measures');
    end
else
    tDiff=t0time;
end

if(isfield(outFNIR,'time'))
    outFNIR.time=outFNIR.time-tDiff;
end

if(isfield(outFNIR,'t0')&&~isfield(outFNIR,'datetime'))
    %if we don't have datetime field, but do have t0, build datetime
    outFNIR.datetime=outFNIR.t0+(duration(0,0,outFNIR.time));
elseif(~isfield(outFNIR,'t0')&&isfield(outFNIR,'datetime'))
    %if we have datetime field, but don't have t0, build t0
    outFNIR.t0=outFNIR.datetime(1)-(duration(0,0,outFNIR.time(1)));
end

if(isfield(outFNIR,'t0'))
    outFNIR.t0=fnirStruct.t0+duration(0,0,tDiff);
end


if(isfield(outFNIR,'markers'))
   if(istable(outFNIR.markers))
      if(~isempty(outFNIR.markers))
          outFNIR.markers.Time = outFNIR.markers.Time - tDiff;
      end
   elseif(isfield(outFNIR.markers,'data'))
       outFNIR.markers.data(:,1)= outFNIR.markers.data(:,1)-tDiff;
   elseif(~isempty(outFNIR.markers))
      outFNIR.markers(:,1)= outFNIR.markers(:,1)-tDiff;
   end
end

if isfield(outFNIR, 'blocks') && ~isempty(outFNIR.blocks)
    for bk = 1:length(outFNIR.blocks)
        outFNIR.blocks(bk).startTime = outFNIR.blocks(bk).startTime - tDiff;
        outFNIR.blocks(bk).endTime = outFNIR.blocks(bk).endTime - tDiff;
    end
end

if(isfield(outFNIR,'raw'))
   %outFNIR.raw(:,1)= outFNIR.raw(:,1)-t0time;
end

if(pf2_base.isnestedfield(outFNIR,'Aux')) && ~isempty(outFNIR.Aux)
    auxFields=fieldnames(outFNIR.Aux);
    % Skip known time fields that are handled separately below
    timeFieldNames = {'t', 'time', 'Time', 'elapsedTime'};
    for f=1:length(auxFields)
    	curFieldName=auxFields{f};
        % Skip if this is a known time field (handled below) or not a numeric array
        if ismember(curFieldName, timeFieldNames)
            continue;
        end
        curField = outFNIR.Aux.(curFieldName);
        % Only modify numeric arrays with at least 2D where column 1 might be time
        if isnumeric(curField) && ismatrix(curField) && size(curField,1) > 1 && size(curField,2) >= 1
            outFNIR.Aux.(curFieldName)(:,1) = curField(:,1) - tDiff;
        elseif istable(curField)
            % Handle flattened Aux tables — shift the time column
            tblVars = curField.Properties.VariableNames;
            timeCol = intersect(timeFieldNames, tblVars);
            if ~isempty(timeCol) && isnumeric(curField.(timeCol{1}))
                outFNIR.Aux.(curFieldName).(timeCol{1}) = ...
                    curField.(timeCol{1}) - tDiff;
            end
        end
    end
end

if(pf2_base.isnestedfield(outFNIR,'Aux.t'))
    outFNIR.Aux.t(:,1)= outFNIR.Aux.t(:,1)-tDiff;
end

if(pf2_base.isnestedfield(outFNIR,'Aux.time'))
    outFNIR.Aux.time(:,1)= outFNIR.Aux.time(:,1)-tDiff;
end