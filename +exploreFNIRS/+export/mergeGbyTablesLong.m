function mergedTables=mergeGbyTablesLong(gbyTables,bioMarkers,channelIndexes,times,exportAux,exportROI,channelLabels)
% MERGEGBYTABLESLONG Merge grouped fNIRS tables into long format for export
%
% Combines multiple grouped-by tables from exploreFNIRS analysis into a
% single long-format table suitable for statistical software (R, SPSS, etc.).
% Long format has one row per observation with columns for grouping variables.
%
% Syntax:
%   mergedTables = mergeGbyTablesLong(gbyTables, bioMarkers, channelIndexes, ...
%       times, exportAux, exportROI, channelLabels)
%
% Inputs:
%   gbyTables      - Cell array of grouped data tables from exploreFNIRS
%   bioMarkers     - Cell array of biomarker names to include
%                    Default: {'HbO','HbR','HbDiff','HbTotal','CBSI'}
%   channelIndexes - Vector of channel indices to export (default: [] = all)
%   times          - Time points to include (default: [] = all)
%   exportAux      - Include auxiliary data (default: false)
%   exportROI      - Include ROI-averaged data (default: false)
%   channelLabels  - Cell array of channel name strings (default: numbers)
%
% Outputs:
%   mergedTables   - Combined table in long format with columns:
%                    Subject, Group, Condition, Channel, Time, Value, etc.
%
% Notes:
%   - Long format is preferred for mixed-effects models in R (lme4)
%   - Each channel/time/biomarker combination becomes a separate row
%   - Compatible with tidyverse and ggplot2 for visualization
%
% Example:
%   % Export HbO and HbR for channels 1-10
%   longTable = mergeGbyTablesLong(gbyData, {'HbO','HbR'}, 1:10);
%   writetable(longTable, 'export_long.csv');
%
% See also: mergeGbyTablesWide, exploreFNIRS


if(nargin<6)
    exportROI=false;
end

if(nargin<5)
    exportAux=false;
end

if(nargin<4)
    times=[];
end

if(nargin<3)
    channelIndexes=[];
end

if(nargin<7)
    channelLabels=cellstr(num2str(channelIndexes));
else
    channelLabels=cellstr(channelLabels);
end

if(isempty(channelIndexes))
    % Export All channelIndexes , ROIs etc
   emptyChannelFlag=true;
else
    emptyChannelFlag=false;
end

if((~exportROI&&~exportAux)) % export parameters by themself, or all channelIndexes
   exportFNIR=true; 
elseif(isempty(channelIndexes)) %used in mass export
   exportFNIR=true; 
else
    exportFNIR=false;
end



if(nargin<2)
    bioMarkers={'HbO','HbR','HbDiff','HbTotal','CBSI'};
end
    
mergedTables=table();%ExFNIRS.selectedTable;



if(isempty(gbyTables))
    mergedTables=[];
    return;
end



for g=1:length(gbyTables)
    curGby=gbyTables(g);
    
    if(isempty(curGby))
        continue;
    end
    
    if(iscell(curGby)&&length(curGby)==1)
       curGby=curGby{1}; 
    end
    
    curBarGA=curGby.gbyGrandBarFlat;

    if(exportROI&&(emptyChannelFlag)&&pf2_base.isnestedfield(curBarGA,'ROI.HbO.data'))
       numROI=size(curBarGA.ROI.HbO.data,2);
       ROIs=1:numROI;
    elseif(exportROI&&~emptyChannelFlag&&pf2_base.isnestedfield(curBarGA,'ROI.HbO.data'))
        numROI=length(channelIndexes);
        ROIs=channelIndexes;
    else
       numROI=0; 
    end
    
    %numRows=size(tempTable,1);
    if(emptyChannelFlag&&exportFNIR)
        numCh=size(curBarGA.HbO.data,2);
        channelIndexes=1:numCh;
        channelLabels=cellstr(num2str(channelIndexes(:)));
    elseif(exportFNIR)
       numCh=length(channelIndexes);
    else
       numCh=0;
    end
    if(isempty(times))
        numTimes=length(curBarGA.time);
        times=curBarGA.time;
    else
        numTimes=length(times);
    end
    
    for tIdx=1:numTimes
        t=times(tIdx);
        tempTable=curGby.gbyTables;
        tDataIdx=find(curBarGA.time==t,1);
        if(isempty(tDataIdx))
            continue;
        end
        t_end=curBarGA.segmentTimes(tDataIdx,3);
        %tempTable.('BioM')(:,1)=string(curBioM);
        tempTable.('Time')(:,1)=string(num2str(round(t),'%.0f'));
        tempTable.('TimeStart')(:,1)=string(num2str(t,'%.2f'));
        tempTable.('TimeEnd')(:,1)=string(num2str(t_end,'%.2f'));

        if(exportFNIR&&~isempty(bioMarkers))
            for b=1:length(bioMarkers)
                curBioM=bioMarkers{b};

                for c=1:numCh
                    chNum=channelIndexes(c);
                    chLabel = channelLabels{c};
                    chName=sprintf('Opt%s_%s',chLabel,curBioM); 


                    tempTable.(chName)(:,1)=nan;
                    tempTable.(chName)(tempTable{:,'missingFNIRS'}~=1,1)=permute(curBarGA.(curBioM).data(tDataIdx,chNum,:),[3,1,2]);
                    tempTable.(chName)(tempTable{:,'missingFNIRS'}==1,1)=nan;
                end

            end
        end
        
        if(exportROI&&~isempty(bioMarkers)&&pf2_base.isnestedfield(curBarGA,'ROI.HbO.data'))

            totalROI=size(curBarGA.ROI.HbO.data,2);
            for b=1:length(bioMarkers)
                curBioM=bioMarkers{b};

                for c=1:numROI

                    curIdx=ROIs(c);

                    if(pf2_base.isnestedfield(curBarGA,'ROI.info')&&~isempty(curBarGA.ROI.info))
                        roi_label_part=sprintf('_%s',curBarGA.ROI.info.Properties.RowNames{curIdx});
                   else
                        roi_label_part=''; 
                    end

                    chName=sprintf('ROI%i%s_%s',curIdx,roi_label_part,curBioM); 


                    tempTable.(chName)(:,1)=nan;
                    tempTable.(chName)(tempTable{:,'missingFNIRS'}~=1,1)=permute(curBarGA.ROI.(curBioM).data(tDataIdx,curIdx,:),[3,1,2]);
                    tempTable.(chName)(tempTable{:,'missingFNIRS'}==1,1)=nan;

                end

            end
        end

        if(exportAux&&isfield(curBarGA,'Aux'))
             curAuxFields=fieldnames(curBarGA.Aux);
             for aux=1:length(curAuxFields)
                curAuxName=curAuxFields{aux};
                curAux= curBarGA.Aux.(curAuxName);
                numAuxCh=size(curAux.data,2);
    
                if(isfield(curAux,'varNames'))
                    curVarNames=curAux.varNames;
                else
                    curVarNames={};
                end
    
                for ch=1:numAuxCh
                    if(numAuxCh==1)
                        newAuxName=sprintf('aux_%s',curAuxName);
                    elseif(isempty(curVarNames))
                        newAuxName=sprintf('aux_%s_%i',curAuxName,ch);
                    else
                        newAuxName=sprintf('aux_%s_%s',curAuxName,curVarNames{ch});
                    end

                       tempTable.(newAuxName)(:,1)=nan;
                       tempTable.(newAuxName)(:,1)=permute(curAux.data(tDataIdx,ch,:),[3,1,2]);
                       %tempTable.(newAuxName)(tempTable{:,'missingAux'}~=1,1)=permute(curAux.data(tDataIdx,ch,:),[3,1,2]);
                       %tempTable.(newAuxName)(tempTable{:,'missingAux'}==1,1)=nan;
                   
                end

            end

        end


        mergedTables=mergeTables(mergedTables,tempTable);
    end
    
    %else % No fnirs info
    %    tempTable=curGby.gbyTables;
    %    mergedTables=mergeTables(mergedTables,tempTable);
    %end
    
    
end

end



function mergedTables=mergeTables(table1,table2)

if(isempty(table1))
    mergedTables=table2;
    return;
elseif(isempty(table2))
    mergedTables=table1;
    return;
end

t1Vars=table1.Properties.VariableNames;
t2Vars=table2.Properties.VariableNames;
  
for i=1:length(t1Vars)
    curVar=t1Vars{i};
    if(~ismember(curVar,t2Vars))
        srcCol=table1.(curVar);
        if(ischar(srcCol) || isstring(srcCol) || iscellstr(srcCol))
            table2.(curVar)=strings(size(table2,1),1);
        else
            table2.(curVar)=nan(size(table2,1),1);
        end
    end
end

for i=1:length(t2Vars)
    curVar=t2Vars{i};
    if(~ismember(curVar,t1Vars))
        srcCol=table2.(curVar);
        if(ischar(srcCol) || isstring(srcCol) || iscellstr(srcCol))
            table1.(curVar)=strings(size(table1,1),1);
        else
            table1.(curVar)=nan(size(table1,1),1);
        end
    end
end

mergedTables=[table1;table2];

          
end