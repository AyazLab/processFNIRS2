function mergedTables=mergeGbyTablesWide(gbyTables,bioMarkers,channels,times,exportAux,exportROI,optodeNames)
% MERGEGBYTABLESWIDE Merge grouped fNIRS tables into wide format for export
%
% Combines multiple grouped-by tables from exploreFNIRS analysis into a
% single wide-format table suitable for spreadsheet analysis (Excel, etc.).
% Wide format has one row per subject with columns for each channel/biomarker.
%
% Syntax:
%   mergedTables = mergeGbyTablesWide(gbyTables, bioMarkers, channels, ...
%       times, exportAux, exportROI, optodeNames)
%
% Inputs:
%   gbyTables    - Cell array of grouped data tables from exploreFNIRS
%   bioMarkers   - Cell array of biomarker names to include
%                  Default: {'HbO','HbR','HbDiff','HbTotal','CBSI'}
%   channels     - Vector of channel indices to export (default: [] = all)
%   times        - Time points to include (default: [] = all)
%   exportAux    - Include auxiliary data (default: false)
%   exportROI    - Include ROI-averaged data (default: false)
%   optodeNames  - Cell array of optode/channel names (default: zero-padded
%                  numbers from pf2_base.channelLabels)
%
% Outputs:
%   mergedTables - Combined table in wide format with columns:
%                  Subject, Group, HbO_Ch1, HbO_Ch2, ..., HbR_Ch1, ...
%
% Notes:
%   - Wide format is preferred for ANOVA in SPSS or Excel pivot tables
%   - Column names follow pattern: BioMarker_Channel
%   - One row per subject/condition combination
%
% Example:
%   % Export all biomarkers for channels 1-18
%   wideTable = mergeGbyTablesWide(gbyData, {'HbO','HbR'}, 1:18);
%   writetable(wideTable, 'export_wide.csv');
%
% See also: mergeGbyTablesLong, exploreFNIRS

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
    channels=[];
end

if(nargin<7)
    optodeNames=pf2_base.channelLabels(channels);
else
    optodeNames=cellstr(optodeNames);
end

if(isempty(channels))
    emptyChannelFlag=true;
else
   emptyChannelFlag=false; 
end


if((~exportROI&&~exportAux)||emptyChannelFlag) %isempty used when exporting all data
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
    tempTable=curGby.gbyTables;
   
    
    %numRows=size(tempTable,1);
    if(emptyChannelFlag&&exportFNIR)
        numCh=size(curBarGA.HbO.data,2);
        channels=1:numCh;
        optodeNames=pf2_base.channelLabels(channels);
    elseif(exportFNIR)
       numCh=length(channels); 
    else
       numCh=0; 
    end
    
    if(emptyChannelFlag&&exportROI&&pf2_base.isnestedfield(curBarGA,'ROI.HbO'))
        numROI=size(curBarGA.ROI.HbO.data,2);
        ROIs=1:numROI;
    elseif(exportFNIR&&pf2_base.isnestedfield(curBarGA,'ROI.HbO'))
       numROI=size(curBarGA.ROI.HbO.data,2);
       ROIs=1:numROI;
    else
       numROI=0; 
    end
    
    if(isempty(times))
        numTimes=length(curBarGA.time);
        times=curBarGA.time;
    else
        numTimes=length(times);
    end

    numBarGATimes=length(curBarGA.time);
    
    if(exportFNIR)
        for b=1:length(bioMarkers)
            curBioM=bioMarkers{b};
            for c=1:numCh
                chNum=channels(c);
                chName=optodeNames{c};
                for t=1:numBarGATimes
                    if(ismember(curBarGA.time(t),times))
                       if(numTimes==1)
                          varName=sprintf('%s_Opt%s',curBioM,chName); 
                       else
                          varName=sprintf('%s_Opt%s_t%.0f',curBioM,chName,curBarGA.time(t)); 
                       end
                       varName(varName=='-')='_';
                       tempTable.(varName)(tempTable{:,'missingFNIRS'}~=1,1)=permute(curBarGA.(curBioM).data(t,chNum,:),[3,1,2]);
                    end
                end
            end
        end
    end
    
    if(exportROI&&pf2_base.isnestedfield(curBarGA,'ROI.HbO'))
        for b=1:length(bioMarkers)
            curBioM=bioMarkers{b};
            for c=1:numROI
                chNum=ROIs(c);
                
               if(pf2_base.isnestedfield(curBarGA,'ROI.info')&&~isempty(curBarGA.ROI.info))
                    roi_label_part=sprintf('_%s',curBarGA.ROI.info.Properties.RowNames{c});
               else
                    roi_label_part=''; 
               end
                for t=1:numBarGATimes
                    if(ismember(curBarGA.time(t),times))

                       

                       if(numTimes==1)
                          varName=sprintf('%s_ROI%i%s',curBioM,chNum,roi_label_part); 
                       else
                          varName=sprintf('%s_ROI%i%s_t%.0f',curBioM,chNum,roi_label_part,curBarGA.time(t)); 
                       end
                       varName(varName=='-')='_';
                       tempTable.(varName)(tempTable{:,'missingFNIRS'}~=1,1)=permute(curBarGA.ROI.(curBioM).data(t,chNum,:),[3,1,2]);
                    end
                end
            end
        end
    end
    
     if(exportAux&&isfield(curBarGA,'Aux'))
         %warning('To-do add AUX fields to export wide'); % trouble is syncing up timing between each
         
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

                for t=1:numBarGATimes
                    if(ismember(curBarGA.time(t),times))
                       if(numTimes==1)
                          varName=sprintf('%s',newAuxName); 
                       else
                          varName=sprintf('%s_t%.0f',newAuxName,curBarGA.time(t)); 
                       end
                       varName(varName=='-')='_';
                       %tempTable.(varName)(tempTable{:,'emptyAux'}~=1,1)=permute(curAux.data(t,ch,:),[3,1,2]);
                       tempTable.(varName)(:,1)=permute(curAux.data(t,ch,:),[3,1,2]);
                    end
                end
            end
            
         end
     end
    
    mergedTables=mergeTables(mergedTables,tempTable);
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
        if(ischar(curVar))
            table2.(curVar)=strings(size(table2,1),1);
        elseif(isnumeric(curVar))
            table2.(curVar)=nan(size(table2,1),1);
        end
    end
end

for i=1:length(t2Vars)
    curVar=t2Vars{i};
    if(~ismember(curVar,t1Vars))
        if(ischar(curVar))
            table1.(curVar)=strings(size(table1,1),1);
        elseif(isnumeric(curVar))
            table1.(curVar)=nan(size(table1,1),1);
        end
    end
end

mergedTables=[table1;table2];

          
end