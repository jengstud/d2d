% clear compiled c-files

function arClearCFiles

[~, c_version_code] = arGetVersion;

filelist = dir;

for j=1:length(filelist)
    indexes = strfind(filelist(j).name, 'arSimuCalcFun_');
    if(~isempty(indexes))
        delete(filelist(j).name);
    end
end

filelist = dir(['./Compiled/' c_version_code]);

for j=1:length(filelist)
    indexes = strfind(filelist(j).name, 'mex');
    if(isempty(indexes) && ~strcmp(filelist(j).name, '.') && ~strcmp(filelist(j).name, '..'))
        delete(['./Compiled/' c_version_code '/' filelist(j).name]);
    end
end
