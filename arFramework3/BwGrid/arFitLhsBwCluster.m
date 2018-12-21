% arFitLhsBwCluster(Nfit,nfit)
%
% arFitLhsBwCluster performs arFitLHS on the BwGrid by automatically
% generating scripts (startup, moab, matlab) and calling them.
%
%   Nfit    total number of fits as used by arFitLHS(Nfit)
%   nfit    number of fits on an individual core
%           (usually something between  1 and 10)
%
% The number of cores in a node is by default 5 as specified in
% arClusterConfig.m. The number of nodes is calculated from Nfit and nfit
% (and 5 cores per node).
% 
% Example:
%     arLoadLatest                      % load some workspace
%     arFitLhsBwCluster(1000,10)        % LHS1000 with 10 Fits per core
% 
%     "Call m_20181221T154020_D13811_results.m manually after the analysis is finished!"
% 
%     m_20181221T154020_D13811_results  % follow the advice (wait and collect the results using the automatically written function
%     results                           % contains the results
% 
% See also arClusterConfig, arFitLHS

function arFitLhsBwCluster(Nfit,nfit)

fprintf('arFitLhsBwCluster.m: Generating bwGrid config ...\n');
conf = arClusterConfig;
if (nfit*conf.n_inNode>Nfit)
    error('For %i cores per node, and a total of %i fits, it''s not meaninful to make %i fits on each core.',conf.n_inNode,Nfit,nfit);
end
conf.n_calls = ceil((Nfit/conf.n_inNode)/nfit);

fprintf('arFitLhsBwCluster.m: Writing startup file %s ...\n',conf.file_startup);
arWriteClusterStartup(conf);

fprintf('arFitLhsBwCluster.m: Writing moab file %s ...\n',conf.file_moab);
arWriteClusterMoab(conf);

global ar
save(conf.file_ar_workspace,'ar');

fprintf('arFitLhsBwCluster.m: Writing matlab file %s ...\n',conf.file_matlab);
% nfit = ceil(Nfit/(conf.n_calls*conf.n_inNode));
fprintf('%i fits will be performed on %i nodes and with %i cores at each node.\n',nfit,conf.n_calls,conf.n_inNode);
WriteClusterMatlabFile(conf,nfit,Nfit); 

fprintf('arFitLhsBwCluster.m: Starting job in background ...\n');
system(sprintf('bash %s\n',conf.file_startup));

fprintf('arFitLhsBwCluster.m: Write matlab file for collecting results ...\n');
WriteClusterMatlabResultCollection(conf)
fprintf('Call %s manually after the analysis is finished!\n',conf.file_matlab_results);


function WriteClusterMatlabResultCollection(conf)

mcode = {
    ['cd ',conf.pwd], ...
    ['matFiles = dir([''',conf.save_path,''',''/result*.mat'']);'], ...
    'matFiles = {matFiles.name};',...
    'fprintf(''%i result workspaced will be collected ...\n'',length(matFiles));', ...
    'results = struct;', ...
    'for i=1:length(matFiles)', ...
    ['    tmp = load([''',conf.save_path,''',filesep,matFiles{i}]);'], ...
    '    if i==1', ...
    '        fn = fieldnames(tmp.result);', ...
    '    end', ...
    '    for f=1:length(fn)', ...
    '        if i==1', ...
    '            if ischar(tmp.result.(fn{f}))', ...
    '                results.(fn{f}) = {tmp.result.(fn{f})};', ...
    '            else', ...
    '                results.(fn{f}) = tmp.result.(fn{f});', ...
    '            end', ...
    '        elseif ischar(tmp.result.(fn{f}))', ...
    '            results.(fn{f}){end+1} = tmp.result.(fn{f});', ...
    '        elseif length(tmp.result.(fn{f}))==1', ...
    '            results.(fn{f}) = [results.(fn{f}),tmp.result.(fn{f})];', ...
    '        elseif size(tmp.result.(fn{f}),2)==length(ar.p) && size(tmp.result.(fn{f}),1) == tmp.result.nfit', ...
    '            results.(fn{f}) = [results.(fn{f});tmp.result.(fn{f})];', ...
    '        elseif size(tmp.result.(fn{f}),1) == 1', ...
    '            results.(fn{f}) = [results.(fn{f}),tmp.result.(fn{f})];', ...
    '        elseif size(tmp.result.(fn{f}),2) == 1', ...
    '            results.(fn{f}) = [results.(fn{f});tmp.result.(fn{f})];', ...
    '        end', ...
    '    end', ...
    'end', ...
    '', ...
    ['save([''',conf.name,''',''_results.mat''], ''results'');'], ...
    };

fid = fopen(conf.file_matlab_results,'w');
for i=1:length(mcode)
    fprintf(fid,'%s\n',mcode{i});
end
fclose(fid);



% The following variables are available in matlab (provided by moab file)
% icall     call/node number
% iInNode   for parallelization within a node
% arg1      further argument (if required
%
% Nfit denotes the total LHS size (total number of fits), nfit the number
% of fits within one call
function WriteClusterMatlabFile(conf,nfit,Nfit)

mcode = {
    ['cd ',conf.pwd], ...
    ['addpath(''',conf.d2dpath,''');'], ...
    'arInit;', ...
    'global ar', ...
    ['load(''',conf.file_ar_workspace,''');'],...
    '', ...
    ['conf.n_inNode = ',num2str(conf.n_inNode),';'],...
    ['conf.save_path = ''',conf.save_path,''';'],...
    ['nfit = ',num2str(nfit),';'],...
    ['Nfit = ',num2str(Nfit),';'],...
    '', ...
    'fields = {...',...
    '    ''ps_start'',...',...
    '    ''ps'',...     ',...
    '    ''ps_errors'',...   ',...
    '    ''chi2s_start'',...     ',...
    '    ''chi2sconstr_start'',...    ',...
    '    ''chi2s'',...     ',...
    '    ''chi2sconstr'',...    ',...
    '    ''exitflag'',...     ',...
    '    ''timing'',...    ',...
    '    ''fun_evals'',...     ',...
    '    ''iter'',...     ',...
    '    ''optim_crit''};',...
    '',...
    'indLhs = (icall-1)*conf.n_inNode + iInNode;',...
    'doneFits = (indLhs-1)*nfit;',...
    'arFitLHS(min(nfit,Nfit-doneFits),indLhs);',...
    '',...
    'result = struct;',...
    'for ifield = 1:length(fields)',...
    '    result.(fields{ifield}) = ar.(fields{ifield});',...
    'end',...
    'result.icall = icall;',...
    'result.iInNode = iInNode;',...
    'result.arg1 = arg1;',...
    'result.indLhs = indLhs;',...
    'result.Nfit = Nfit;',...
    'result.nfit = nfit;',...
    'result.file = [conf.save_path,filesep,''result_'',num2str(indLhs)];',...
    '',...
    'save(result.file,''result'');',...
    };



fid = fopen(conf.file_matlab,'w');
for i=1:length(mcode)
    fprintf(fid,'%s\n',mcode{i});
end
fclose(fid);





