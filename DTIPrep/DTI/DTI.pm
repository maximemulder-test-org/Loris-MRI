=pod

=head1 NAME

DTI --- A set of utility functions for performing common tasks relating to DTI data (particularly with regards to perform DTI QC)

=head1 SYNOPSIS

use DTI;

my $dbh = DTI::connect_to_db();

=head1 DESCRIPTION

Really a mismatch of utility functions, primarily used by DTIPrep_pipeline.pl

=head1 METHODS

=cut

package DTI;

use Exporter();
use File::Basename;
use Getopt::Tabular;
use File::Path          'make_path';
use Date::Parse;
use MNI::Startup        qw(nocputimes);
use MNI::Spawn;
use MNI::FileUtilities  qw(check_output_dirs);

@ISA        = qw(Exporter);

@EXPORT     = qw();
@EXPORT_OK  = qw(createOutputFolders getFiles sortParam insertMincHeader create_processed_maps createNoteFile);

=pod
Create DTIPrep pipeline output folders.
=cut
sub createOutputFolders{
    my  ($outdir, $subjID, $visit, $protocol, $runDTIPrep) = @_;   
    
    my  $QC_out     =   $outdir . "/" .
                        $subjID . "/" .
                        $visit  . "/mri/processed/" .
                        substr(basename($protocol),0,-4);

    system("mkdir -p -m 755 $QC_out")   unless (-e $QC_out || !$runDTIPrep);


    return  ($QC_out) if (-e $QC_out);
}

=pod
Subroutine that will read the content of a directory and return a list of files matching the string given in argument with $match.
=cut
sub getFilesList {
    my ($dir, $match)   = @_;
    my (@files_list)    = ();

    ## Read directory $dir and stored its content in @entries 
    opendir  (DIR,"$dir")   ||  die "cannot open $dir\n";
    my @entries = readdir(DIR);
    closedir (DIR);

    ## Keep only files that match string stored in $match
    @files_list = grep(/$match/i, @entries);
    ## Add directory path to each element (file) of the array 
    @files_list = map  {"$dir/" . $_} @files_list;    

    return  (\@files_list);
}

=pod
Functionthat parses files in native MRI directory and grab the T1 acquisition based on $t1_scan_type.
If no anat was found, will return undef.
If multiple anat were found, will return the first anat of the list.
=cut
sub getAnatFile {
    my ($nativedir, $t1_scan_type)  = @_;

    # Fetch files in native directory that matched t1_scan_type
    my $anat_list   = DTI::getFilesList($nativedir, $t1_scan_type);

    # Return undef if no anat found, first anat otherwise
    if (@$anat_list == 0) { 
        return undef; 
    } else { 
        my $anat    = @$anat_list[0];
        return $anat;
    }
}

=pod
Function that parses files in native MRI directories and fetch DTI files. This function will also concatenate together multipleDTI files if DTI acquisition performed accross several DTI scans.
=cut
sub getRawDTIFiles{
    my ($nativedir, $DTI_volumes)   = @_;
    
    ## Get all mincs contained in native directory
    my ($mincs_list)    = DTI::getFilesList($nativedir, 'mnc$');

    ## Grab the mincs I want, a.k.a. with minc file with $DTI_volumes 
    my @DTI_frames  = split(',',$DTI_volumes);
    my @DTIs_list   = (); 
    foreach my $mnc (@$mincs_list) {
        if  (`mincinfo -dimnames $mnc` =~ m/time/)    {
            my $time    = `mincinfo -dimlength time $mnc`;
            chomp($time);
            if  ($time ~~ \@DTI_frames) {
                push (@DTIs_list, $mnc);
            }
        }
    }

    ## Return list of DTIs with the right volume numbers
    return  (\@DTIs_list);
}

=pod
Function that will copy the DTIPrep protocol used to the output directory of DTIPrep. 
=cut
sub copyDTIPrepProtocol {
    my ($DTIPrepProtocol, $QCProt)    =   @_;

    my $cmd = "cp $DTIPrepProtocol $QCProt";
    system($cmd)    unless (-e $QCProt);

    if (-e $QCProt) {
        return 1;
    } else {
        return undef;
    }
}





=pod
Read DTIPrep XML protocol and return information into a hash.
- Inputs: - $DTIPrepProtocol    = XML protocol used (or that has been used) to run DTIPrep
- Output: - $protXMLrefs        = dereferenced hash containing DTIPrep protocol as follows:
                entry   => 'QC_QCOutputDirectory'       => {}
                        => 'QC_QCedDWIFileNameSuffix'   => { 
                                                            'value' => '_QCed.nrrd'
                                                                                                                                                                  },
                        => 'IMAGE_bCheck' => {
                                        'entry' => {
                                                  'IMAGE_size' => {
                                                                  'value' => [
                                                                             '96',
                                                                             '96',
                                                                             '65'
                                                                           ]
                                                                },
                                                  'IMAGE_reportFileMode' => {
                                                                            'value' => '1'
                                                                          }, 
                                        ...                
                                        'value' => 'Yes'
                                        },
                        => 'QC_badGradientPercentageTolerance' => {
                                    etc...
=cut
sub readDTIPrepXMLprot {
    my ($DTIPrepProtocol)   = @_;

    my $xml             = new XML::Simple;
    my ($protXMLrefs)   = $xml->XMLin(  $DTIPrepProtocol,
                                        KeyAttr => {entry => 'parameter'},
                                        ForceArray => ['parameter']
                                     );

    return ($protXMLrefs);
}


=pod
Function that will determine output names based on each DTI file dataset and return a hash of DTIref:
       dti_file_1  -> Raw_nrrd     => outputname
                   -> QCed_nrrd    => outputname
                   -> QCTxtReport  => outputname
                   -> QCXmlReport  => outputname
                   -> QCed_minc    => outputname
                   -> QCProt       => outputname
       dti_file_2  -> Raw_nrrd     => outputname etc...
=cut
sub createDTIhashref {
    my ($DTIs_list, $anat, $QCoutdir, $DTIPrepProtocol, $protXMLrefs, $QCed2_step)    =   @_;
    my %DTIrefs;

    foreach my $dti_file (@$DTIs_list) {

        # Raw nrrd file to be processed
        my $dti_name        = substr(basename($dti_file), 0, -4);
        $DTIrefs->{$dti_file}->{'Raw_nrrd'}                 = $QCoutdir . "/" . $dti_name  . ".nrrd"           ;

        # Determine preprocess outputs
        DTI::determinePreprocOutputs($QCoutdir, $dti_file, $DTIPrepProtocol, $protXMLrefs, $QCed2_step);

        # If DTI_bCompute is set to yes, DTIPrep will create FA, RGB, MD, and other output files that we will want to insert in datase
        DTI::determinePostprocOutputs($QCoutdir, $dti_file, $anat, $protXMLrefs);
            
    }
    
    return  ($DTIrefs);
}

=pod
Function that will determine post processing output names (for either DTIPrep or mincdiffusion postprocessing) and append them to $DTIrefs.
- Inputs:   - $QCoutdir         = directory that will contain output files
            - $dti_file         = raw DWI file to be processed
            - $DTIPrepProtocol  = DTIPrepProtocol to copy into output directory
            - $protXMLrefs      = hash containing informations stored in DTIPrep XML protocol (with suffix for the different outputs, among other things) 
- Outputs:  - $DTIrefs{$dti_file}{'Preproc'}{'Output'} fields for DTIPrep preprocessing
=cut
sub determinePreprocOutputs {
    my ($QCoutdir, $dti_file, $DTIPrepProtocol, $protXMLrefs, $QCed2_step)   = @_;

    my $prot_name       = basename($DTIPrepProtocol);
    my $dti_name        = substr(basename($dti_file), 0, -4);

    $DTIrefs->{$dti_file}->{'Preproc'}->{'QCProt'}      = $QCoutdir . "/" . $dti_name  . "_" . $prot_name  ;
    $DTIrefs->{$dti_file}->{'Preproc'}->{'QCXmlReport'} = $QCoutdir . "/" . $dti_name  . "_XMLQCResult.xml";
       
    # These are determined in DTIPrep's XML protocol 
    my $QCTxtReport = $protXMLrefs->{entry}->{QC_reportFileNameSuffix}->{value};
    my $QCed_suffix = $protXMLrefs->{entry}->{QC_QCedDWIFileNameSuffix}->{value};
    $QCed_suffix    = substr($QCed_suffix, 0, -5); # remove .nrrd from QCed suffix

    $DTIrefs->{$dti_file}->{'Preproc'}->{'QCTxtReport'}   = $QCoutdir . "/" . $dti_name  . $QCTxtReport          ;
    $DTIrefs->{$dti_file}->{'Preproc'}->{'QCed_nrrd'}     = $QCoutdir . "/" . $dti_name  . $QCed_suffix . ".nrrd"; 
    $DTIrefs->{$dti_file}->{'Preproc'}->{'QCed_minc'}     = $QCoutdir . "/" . $dti_name  . $QCed_suffix . ".mnc" ;

    # if a secondary QC file is written during INTERLACE_bCheck step (before motion and eddy curent corrections)
    my $QCed2_suffix= $protXMLrefs->{entry}->{INTERLACE_bCheck}->{entry}->{$QCed2_step}->{value};
    if ($QCed2_suffix) {
        $QCed2_suffix   = substr($QCed2_suffix, 0, -5); # remove .nrrd from QCed2 suffix
        $DTIrefs->{$dti_file}->{'Preproc'}->{'QCed2_nrrd'}= $QCoutdir . "/" . $dti_name . $QCed2_suffix . ".nrrd";
        $DTIrefs->{$dti_file}->{'Preproc'}->{'QCed2_minc'}= $QCoutdir . "/" . $dti_name . $QCed2_suffix . ".mnc" ;
    }
}


=pod
Function that will determine post processing output names (for either DTIPrep or mincdiffusion postprocessing) and append them to $DTIrefs.
- Inputs:   - $QCoutdir     = directory that will contain output files
            - $dti_file     = raw DWI file to be processed
            - $anat         = anatomic T1 image to be used for mincdiffusion postprocessing
            - $protXMLrefs  = hash containing informations stored in DTIPrep XML protocol (with suffix for the different outputs, among other things) 
- Outputs:  - $DTIrefs{$dti_file}{'Postproc'}{'Tool'} field storing which postprocessing pipeline was used
            - $DTIrefs{$dti_file}{'Postproc'}{'Output'} fields for DTIPrep postprocessing
=cut
sub determinePostprocOutputs {
    my ($QCoutdir, $dti_file, $anat, $protXMLrefs) = @_;

    # Determine QCed file suffix to be used for postprocess output files
    my $QCed_suffix = $protXMLrefs->{entry}->{QC_QCedDWIFileNameSuffix}->{value};
    $QCed_suffix    = substr($QCed_suffix, 0, -5); # remove .nrrd from QCed suffix

    # Check whether DTIPrep will create FA, RGB and other postprocessing outputs (DTI_bCompute == Yes)
    my $bCompute    = $protXMLrefs->{entry}->{DTI_bCompute}->{value};

    if ($bCompute eq 'Yes') {
        
        $DTIrefs->{$dti_file}->{'Postproc'}->{'Tool'} = 'DTIPrep';
        DTI::determineDTIPrepPostprocOutputs($QCoutdir, $dti_file, $QCed_suffix, $protXMLrefs);

    } elsif ($bCompute eq 'No') {
    
        $DTIrefs->{$dti_file}->{'Postproc'}->{'Tool'} = 'mincdiffusion';
        DTI::determineMincdiffusionPostprocOutputs($QCoutdir, $dti_file, $QCed_suffix, $anat);

    }
}

=pod
Function that will determine DTIPrep's postprocessing output names (based on the XML protocol) and append them to $DTIrefs
- Inputs:   - $QCoutdir     = directory that will contain output files
            - $dti_file     = raw DWI file to be processed
            - $protXMLrefs  = hash containing informations stored in DTIPrep XML protocol (with suffix for the different outputs, among other things) 
- Outputs:  - $DTIrefs{$dti_file}{'Postproc'}{'Output'} fields for DTIPrep postprocessing
=cut
sub determineDTIPrepPostprocOutputs {
    my ($QCoutdir, $dti_file, $QCed_suffix, $protXMLrefs) = @_;
    
    # Determine basename of the dti file to be processed
    my $dti_name        = substr(basename($dti_file), 0, -4);

    # 1. Tensor
    # Determine suffix to used for the output
    my $tensor_suffix   = $protXMLrefs->{entry}->{DTI_bCompute}->{entry}->{DTI_tensor}->{value};    
    $tensor_suffix      = $QCed_suffix . substr($tensor_suffix, 0, -5); # remove .nrrd from tensor suffix
    # Determine nrrd and minc names
    $DTIrefs->{$dti_file}->{'Postproc'}->{'tensor_nrrd'}  = $QCoutdir . "/" . $dti_name  . $tensor_suffix . ".nrrd";
    $DTIrefs->{$dti_file}->{'Postproc'}->{'tensor_minc'}  = $QCoutdir . "/" . $dti_name  . $tensor_suffix . ".mnc" ;

    # 2. Baseline DTI image (bvalue = 0) {value} key returns an array with 0 -> Yes/No; 1 -> output suffix to append to DTI tensor suffix
    # Determine suffix to used for the output
    my $baseline_suffix = $protXMLrefs->{entry}->{DTI_bCompute}->{entry}->{DTI_baseline}->{value}[1];    
    $baseline_suffix    = $QCed_suffix . substr($baseline_suffix, 0, -5); # remove .nrrd from baseline suffix
    $DTIrefs->{$dti_file}->{'Postproc'}->{'baseline_nrrd'}  = $QCoutdir . "/" . $dti_name  . $baseline_suffix . ".nrrd";
    $DTIrefs->{$dti_file}->{'Postproc'}->{'baseline_minc'}  = $QCoutdir . "/" . $dti_name  . $baseline_suffix . ".mnc" ;

    # 3. RGB map {value} key returns an array with 0 -> Yes/No; 1 -> output suffix to append to DTI tensor suffix
    # Determine suffix to used for the output
    my $RGB_suffix      = $protXMLrefs->{entry}->{DTI_bCompute}->{entry}->{DTI_colorfa}->{value}[1];
    $RGB_suffix         = $tensor_suffix . substr($RGB_suffix, 0, -5); # remove .nrrd from rgb suffix
    # Determine nrrd and minc names
    $DTIrefs->{$dti_file}->{'Postproc'}->{'RGB_nrrd'}  = $QCoutdir . "/" . $dti_name  . $RGB_suffix . ".nrrd";
    $DTIrefs->{$dti_file}->{'Postproc'}->{'RGB_minc'}  = $QCoutdir . "/" . $dti_name  . $RGB_suffix . ".mnc" ;

    # 4. FA map {value} key returns an array with 0 -> Yes/No; 1 -> output suffix to append to DTI tensor suffix
    # Determine suffix to used for the output
    my $FA_suffix       = $protXMLrefs->{entry}->{DTI_bCompute}->{entry}->{DTI_fa}->{value}[1];
    $FA_suffix          = $tensor_suffix . substr($FA_suffix, 0, -5); # remove .nrrd from FA suffix
    # Determine nrrd and minc names
    $DTIrefs->{$dti_file}->{'Postproc'}->{'FA_nrrd'}  = $QCoutdir . "/" . $dti_name  . $FA_suffix . ".nrrd";
    $DTIrefs->{$dti_file}->{'Postproc'}->{'FA_minc'}  = $QCoutdir . "/" . $dti_name  . $FA_suffix . ".mnc" ;

    # 5. MD map {value} key returns an array with 0 -> Yes/No; 1 -> output suffix to append to DTI tensor suffix
    # Determine suffix to used for the output
    my $MD_suffix       = $protXMLrefs->{entry}->{DTI_bCompute}->{entry}->{DTI_md}->{value}[1];
    $MD_suffix          = $tensor_suffix . substr($MD_suffix, 0, -5); # remove .nrrd from MD suffix
    # Determine nrrd and minc names
    $DTIrefs->{$dti_file}->{'Postproc'}->{'MD_nrrd'}  = $QCoutdir . "/" . $dti_name  . $MD_suffix . ".nrrd";
    $DTIrefs->{$dti_file}->{'Postproc'}->{'MD_minc'}  = $QCoutdir . "/" . $dti_name  . $MD_suffix . ".mnc" ;

    # 6. Isotropic DWI {value} key returns an array with 0 -> Yes/No; 1 -> output suffix to append to DTI tensor suffix
    # Determine suffix to used for the output
    my $IDWI_suffix     = $protXMLrefs->{entry}->{DTI_bCompute}->{entry}->{DTI_idwi}->{value}[1];
    $IDWI_suffix        = substr($IDWI_suffix, 0, -5); # remove .nrrd from isotropic DWI suffix
    # Determine nrrd and minc names
    $DTIrefs->{$dti_file}->{'Postproc'}->{'IDWI_nrrd'}  = $QCoutdir . "/" . $dti_name  . $IDWI_suffix . ".nrrd";
    $DTIrefs->{$dti_file}->{'Postproc'}->{'IDWI_minc'}  = $QCoutdir . "/" . $dti_name  . $IDWI_suffix . ".mnc" ;

}    

=pod
Function that will determine mincdiffusion postprocessing output names and append them to $DTIrefs
- Inputs:   - $QCoutdir     = directory that will contain output files
            - $dti_file     = raw DWI file to be processed
            - $QCed_suffix  = QCed suffix used to create QCed nrrd and determine postprocessing file names
            - $anat         = anatomic T1 file to use for DWI-anat registration
- Outputs:  - $DTIrefs{$dti_file}{'Postproc'} for mincdiffusion postprocessing
=cut
sub determineMincdiffusionPostprocOutputs {
    my ($QCoutdir, $dti_file, $QCed_suffix, $anat) = @_;
    
    # Determine basename of the dti file to be processed
    my $dti_name        = substr(basename($dti_file), 0, -4);

    # Determine basename of the anat file to be processed
    my $anat_name       = substr(basename($anat), 0, -4);

    # Determine mincdiffusion output names    
    $DTIrefs->{$dti_file}->{'Postproc'}->{'FA_minc'}        = $QCoutdir . "/" . $dti_name  . $QCed_suffix . "_FA.mnc"      ;
    $DTIrefs->{$dti_file}->{'Postproc'}->{'RGB_minc'}       = $QCoutdir . "/" . $dti_name  . $QCed_suffix . "_rgb.mnc"     ;
    $DTIrefs->{$dti_file}->{'Postproc'}->{'MD_minc'}        = $QCoutdir . "/" . $dti_name  . $QCed_suffix . "_MD.mnc"      ;
    $DTIrefs->{$dti_file}->{'Postproc'}->{'rgb_pic'}        = $QCoutdir . "/" . $dti_name  . $QCed_suffix . "_RGB.png"     ;
    $DTIrefs->{$dti_file}->{'Postproc'}->{'baseline_minc'}  = $QCoutdir . "/" . $dti_name  . $QCed_suffix . "-frame0.mnc"  ;
    $DTIrefs->{$dti_file}->{'raw_anat_minc'}                = $anat                                              ;
    $DTIrefs->{$dti_file}->{'Postproc'}->{'anat_mask_minc'} = $QCoutdir . "/" . $anat_name . "-n3-bet_mask.mnc"  ;
    $DTIrefs->{$dti_file}->{'Postproc'}->{'anat_mask_diff_minc'} = $QCoutdir . "/" . $anat_name . "-n3-bet_mask-diffspace.mnc"  ;
    $DTIrefs->{$dti_file}->{'Postproc'}->{'preproc_minc'}   = $QCoutdir . "/" . $dti_name . $QCed_suffix . "-preprocessed.mnc" ;

}    

=pod
Function that convert minc file to nrrd or nrrd file to minc. 
(depending on $options)
=cut
sub convert_DTI {
    my  ($file_in, $file_out, $options)    =   @_;

    if  (!$options) { 
        print LOG "---DIED--- No options were define for conversion mnc2nrrd or nrrd2mnc.\n\n\n"; 
    }

    my  $cmd        =   "itk_convert $options --dwi $file_in $file_out";
    print "\n\tConverting $file_in to $file_out (...)\n$cmd\n";
    system($cmd)    unless (-e $file_out);

    if (-e $file_out) {
        return 1;   # successfully converted
    } else {
        return undef;   # failed during conversion
    }
}

=pod
Function that run DTIPrep on nrrd file. 
If QCed file found and secondary QCed file (if defined) is found, will return 1.
Will return undef otherwise
=cut
sub runDTIPrep {
    my  ($raw_nrrd, $protocol, $QCed_nrrd, $QCed2_nrrd)  =   @_;    

    my  $cmd        =   "DTIPrep --DWINrrdFile $raw_nrrd --xmlProtocol $protocol";
    print   "\n\tRunning DTIPrep (...)\n$cmd\n";
    system($cmd)    unless (-e $QCed_nrrd);

    if (($QCed2_nrrd) && ((-e $QCed_nrrd) && (-e $QCed2_nrrd))) {
        return 1;
    } elsif ((!$QCed2_nrrd) && (-e $QCed_nrrd)) {
        return 1;
    } else {
        return undef;
    }
}

=pod

Insert in the minc header all the acquisition arguments except:
    - acquisition:bvalues
    - acquisition:direction_x
    - acquisition:direction_y
    - acquisition:direction_z
    - acquisition:b_matrix

Takes the raw DTI file and the QCed minc file as input and modify the QCed minc file based on the raw minc file's argument.

=cut
sub insertMincHeader {
    my  ($raw_dti, $data_dir, $processed_minc, $QC_report, $DTIPrepVersion)    =   @_;

    # insertion of processed information into $processed_minc
    my ($procInsert)    =   DTI::insertProcessInfo($raw_dti, $data_dir, $processed_minc, $QC_report, $DTIPrepVersion);

    # insert old acquisition, patient and study arguments except for the one modified by DTIPrep (i.e. acquisition:bvalues, acquisition:b_matrix and all acquisition:direction*)
    my  ($acqInsert)    =   DTI::insertAcqInfo($raw_dti, $processed_minc);

    # insert patient information from the raw dataset into the processed files
    my  ($patientInsert)=   DTI::insertFieldList($raw_dti, $processed_minc, 'patient:');

    # insert study information from the raw dataset into the processed files
    my  ($studyInsert)  =   DTI::insertFieldList($raw_dti, $processed_minc, 'study:');

    if (($procInsert) && ($acqInsert) && ($patientInsert) && ($studyInsert)) {
        return 1;
    } else {
        return undef;
    }
}

=pod
This will insert in the header of the processed file processing information.
=cut
sub insertProcessInfo {
    my ($raw_dti, $data_dir, $processed_minc, $QC_report, $DTIPrepVersion) = @_;

    # 1) processing:sourceFile
    my  $sourceFile         =   $raw_dti;
    $sourceFile             =~  s/$data_dir//i;
    my ($sourceFile_insert) = DTI::modify_header('processing:sourceFile', $sourceFile, $processed_minc, '$3, $4, $5, $6');

    # 2) processing:sourceSeriesUID information (dicom_0x0020:el_0x000e field of $raw_dti)
    my  ($seriesUID)        = DTI::fetch_header_info('dicom_0x0020:el_0x000e',$raw_dti,'$3, $4, $5, $6');
    my ($seriesUID_insert)  = DTI::modify_header('processing:sourceSeriesUID', $seriesUID, $processed_minc, '$3, $4, $5, $6');

    # 3) processing:pipeline used
    my ($pipeline_insert)   = DTI::modify_header('processing:pipeline', $DTIPrepVersion, $processed_minc, '$3, $4, $5, $6');

    # 4) processing:processing_date (when DTIPrep was run)
    my  $check_line         =   `cat $QC_report | grep "Check Time"`;
    $check_line             =~  s/Check Time://;  # Only keep date info in $check_line.
    my ($ss,$mm,$hh,$day,$month,$year,$zone)    =   strptime($check_line);
    my $processingDate      =   sprintf("%4d%02d%02d",$year+1900,$month+1,$day);
    my ($date_insert)       = DTI::modify_header('processing:processing_date', $processingDate, $processed_minc, '$3, $4, $5, $6');

    if (($sourceFile_insert) && ($seriesUID_insert) && ($pipeline_insert) && ($date_insert)) {
        return 1;
    } else {
        return undef;
    }
}

=pod
Insert acquisition information extracted from raw DTI dataset and insert it in the processed file. 
If one of the value to insert is not defined, return undef, otherwise return 1.
=cut
sub insertAcqInfo {
    my  ($raw_dti, $processed_minc) = @_;

    # 1) insertion of acquisition:b_value 
    my ($b_value)       = DTI::fetch_header_info('acquisition:b_value',$raw_dti,'$3, $4, $5, $6');
    my ($bvalue_insert) = DTI::modify_header('acquisition:b_value', $b_value, $processed_minc, '$3, $4, $5, $6');

    # 2) insertion of acquisition:delay_in_TR 
    my ($delay_in_tr)   = DTI::fetch_header_info('acquisition:delay_in_TR',$raw_dti,'$3, $4, $5, $6');
    my ($delaytr_insert)= DTI::modify_header('acquisition:delay_in_TR', $delay_in_tr, $processed_minc, '$3, $4, $5, $6');

    # 3) insertion of all the remaining acquisition:* arguments 
    #    [except acquisition:bvalues, acquisition:b_matrix and acquisition:direction* (already in header from nrrd2minc conversion)]
    my  ($acqInsert)    =   DTI::insertFieldList($raw_dti, $processed_minc, 'acquisition:[^dbv]');   

    if  (($bvalue_insert) && ($delaytr_insert) && ($acqInsert)) {
        return 1;
    } else {
        return undef;
    }
}


sub insertFieldList {
    my  ($raw_dti, $processed_minc, $minc_field) = @_;

    # fetches list of arguments starting with $minc_field (i.e. 'patient:'; 'study:' ...)
    my  ($arguments) =   DTI::fetch_header_info($minc_field, $raw_dti, '$1, $2');

    # fetches list of values with arguments starting with $minc_field. Don't remove semi_colon (last option of fetch_header_info).
    my  ($values) =   DTI::fetch_header_info($minc_field, $raw_dti, '$3, $4, $5, $6', 1);

    my  ($arguments_list, $arguments_list_size) =   get_header_list('=', $arguments);
    my  ($values_list, $values_list_size)       =   get_header_list(';', $values);

    my  @insert_failure;
    if  ($arguments_list_size   ==  $values_list_size)  {
        for (my $i=0;   $i<$arguments_list_size;    $i++)   {
            my  $argument   =   @$arguments_list[$i];
            my  $value      =   @$values_list[$i];
            my ($insert)    = DTI::modify_header($argument, $value, $processed_minc, '$3, $4, $5, $6');
            # store in array @insert_failure the arguments that were not successfully inserted in the mincheader
            push (@insert_failure, $argument) if (!$insert);
        }
        # if at least one insertion failed, will return undef, otherwise 1.
        if ($#insert_failure >= 0) {
            return  undef;
        } else {
            return 1;
        }
    # if arguments_list and values_list do not have the same size, will return undef    
    }else {
        return  undef;
    }
}    

=pod
Function that runs minc_modify_header.
=cut
sub modify_header {
    my  ($argument, $value, $minc, $awk) =   @_;
    
    # check if header information not already in minc file
    my $hdr_val =   &DTI::fetch_header_info($argument, $minc, $awk);

    # insert mincheader unless mincheader field already inserted ($hdr_val eq $value)
    my  $cmd    =   "minc_modify_header -sinsert $argument=$value $minc";
    system($cmd)    unless ($value eq $hdr_val);

    # check if header information was indeed inserted in minc file
    my $hdr_val2 =   &DTI::fetch_header_info($argument, $minc, $awk);
    if ($hdr_val2) {
        return 1;
    } else {
        return undef;
    }
}

=pod

=cut
sub fetch_header_info {
    my  ($field, $minc, $awk, $keep_semicolon)  =   @_;

    my  $val    =   `mincheader $minc | grep $field | awk '{print $awk}' | tr '\n' ' '`;
    my  $value  =   $val    if  $val !~ /^\s*"*\s*"*\s*$/;
    $value      =~  s/^\s+//;                           # remove leading spaces
    $value      =~  s/\s+$//;                           # remove trailing spaces
    $value      =~  s/;//   unless ($keep_semicolon);   # remove ";" unless $keep_semicolon is defined

    return  ($value);
}

=pod
Get the list of arguments and values to insert into the mincheader (acquisition:*, patient:* and study:*).
=cut
sub get_header_list {
    my  ($splitter, $fields) =   @_;
    
    my  @tmp    =   split   ($splitter, $fields);
    pop (@tmp);
    my  @items;
    foreach my $item (@tmp) { 
        $item   =~  s/^\s+//;   # remove leading spaces
        $item   =~  s/\s+$//;   # remove trailing spaces
        push    (@items, $item);
    }
    my  $list       =   \@items;
    my  $list_size  =   @$list;
    
    return  ($list, $list_size);
}









=pod
Function that runs diff_preprocess.pl script from the mincdiffusion tools on the QCed minc and raw anat dataset.
- Arguments:- $dti_file: hash key to use to fetch file names (a.k.a. Raw DTI file) 
            - $DTIrefs: hash storing file names to be used
            - $QCoutdir: directory used to create outputs from QC pipeline
- Returns:  - 1 if all outputs were created
            - undef if outputs were not created
=cut
sub mincdiff_preprocess {
    my ($dti_file, $DTIrefs, $QCoutdir) = @_;    
    
    # Initialize variables
        # 1. input data
    my $QCed_minc     = $DTIrefs->{$dti_file}{'Preproc'}{'QCed_minc'};
    my $QCed_basename = substr(basename($QCed_minc),0,-4);
    my $raw_anat      = $DTIrefs->{$dti_file}{'raw_anat_minc'};
        # 2. output data
    my $preproc_minc  = $DTIrefs->{$dti_file}{'Postproc'}{'preproc_minc'};
    my $baseline      = $DTIrefs->{$dti_file}{'Postproc'}{'baseline_minc'};
    my $anat_mask     = $DTIrefs->{$dti_file}{'Postproc'}{'anat_mask_minc'};
    my $anat_mask_diff= $DTIrefs->{$dti_file}{'Postproc'}{'anat_mask_diff_minc'};

    # Run diff_preprocess.pl script 
    `diff_preprocess.pl -anat $raw_anat $QCed_minc $preproc_minc -outdir $QCoutdir`;

    # Check that all output files were created
    if ((-e $preproc_minc) && (-e $anat_mask) && ($anat_mask_diff) && (-e $baseline)) {
        $DTIrefs->{$dti_file}{'mincdiff_preproc_status'}    = "success";
        return 1;
    } else {
        $DTIrefs->{$dti_file}{'mincdiff_preproc_status'}    = "failed";
        return undef;
    }
}









=pod
Function that runs minctensor.pl script from the mincdiffusion tools on the mincdiff preprocessed minc and anatomical mask images.
- Arguments:- $dti_file: hash key to use to fetch file names (a.k.a. Raw DTI file) 
            - $DTIrefs: hash storing file names to be used
            - $QCoutdir: directory used to create outputs from QC pipeline
- Returns:  - 1 if all outputs were created
            - undef if outputs were not created
=cut
sub mincdiff_minctensor {
    my ($dti_file, $DTIrefs, $QCoutdir, $niak_path) = @_;

    # Initialize variables
        # 1. input data
    my $QCed_minc     = $DTIrefs->{$dti_file}{'Preproc'}{'QCed_minc'};
    my $QCed_basename = substr(basename($QCed_minc), 0, -4);
    my $preproc_minc  = $DTIrefs->{$dti_file}{'Postproc'}{'preproc_minc'};
    my $anat_mask     = $DTIrefs->{$dti_file}{'Postproc'}{'anat_mask_minc'};
        # 2. output data
    my $FA            = $DTIrefs->{$dti_file}{'Postproc'}{'FA_minc'};
    my $MD            = $DTIrefs->{$dti_file}{'Postproc'}{'MD_minc'};
    my $RGB           = $DTIrefs->{$dti_file}{'Postproc'}{'RGB_minc'};

    # Run minctensor.pl script  
    `minctensor.pl -mask $anat_mask $preproc_minc -niakdir $niak_path -outputdir $QCoutdir -octave $QCed_basename`;

    # Check that all output files were created
    if ((-e $FA) && (-e $RGB) && (-e $MD)) {
        $DTIrefs->{$dti_file}{'minctensor_status'}  = "success";
        return 1;
    } else {
        $DTIrefs->{$dti_file}{'minctensor_status'}  = "failed";
        return undef;
    }
}









=pod
Function that runs mincpik on the RGB map.
- Arguments:- $dti_file: hash key to use to fetch file names (a.k.a. Raw DTI file) 
            - $DTIrefs: hash storing file names to be used
- Returns:  - 1 if rgb_pic was created
            - undef if rgb_pic was not created
=cut
sub RGBpik_creation {
    my ($dti_file, $DTIrefs) = @_;

    # Initialize variables
        # 1. input file
    my $RGB     = $DTIrefs->{$dti_file}{'Postproc'}{'RGB_minc'};
        # 2. output file
    my $rgb_pic = $DTIrefs->{$dti_file}{'Postproc'}{'rgb_pic'};   

    # Run mincpik on the RGB map
    `mincpik -triplanar -horizontal $RGB $rgb_pic`;

    # Check that the RGB pik was created
    if (-e $rgb_pic) {
        return 1;
    } else {
        return undef;
    }
}










=pod
Function that created FA and RGB maps as well as the triplanar pic of the RGB map. 
=cut
#sub create_processed_maps {
#    my ($dti_file, $DTIrefs, $QCoutdir)   =   @_;
#
#    # Initialize variables
#    my $QCed_minc     = $DTIrefs->{$dti_file}{'Preproc'}{'QCed_minc'};
#    my $QCed_basename = substr(basename($QCed_minc),0,-4);
#    my $FA            = $DTIrefs->{$dti_file}{'Postproc'}{'FA_minc'};
#    my $MD            = $DTIrefs->{$dti_file}{'Postproc'}{'MD_minc'}; 
#    my $RGB           = $DTIrefs->{$dti_file}{'Postproc'}{'RGB_minc'};
#    my $rgb_pic       = $DTIrefs->{$dti_file}{'Postproc'}{'rgb_pic'};
#    my $baseline      = $DTIrefs->{$dti_file}{'Postproc'}{'baseline_minc'};
#    my $preproc_minc  = $DTIrefs->{$dti_file}{'Postproc'}{'preproc_minc'};
#    my $anat_mask     = $DTIrefs->{$dti_file}{'Postproc'}{'anat_mask_minc'};
#    my $anat          = $DTIrefs->{$dti_file}{'raw_anat_minc'};
#
#    # Check if output files already exists
#    if (-e $rgb_pic && $RGB && $MD && $baseline && $anat_mask && $preproc_minc) {
#        return  0;
#    }
#
#    # Run diff_preprocess.pl pipeline if anat and QCed dti exists. Return 1 otherwise
#    if (-e $anat && $QCed_minc) {
#        `diff_preprocess.pl -anat $anat $QCed_minc $preproc_minc -outdir $QCoutdir`   unless (-e $preproc_minc);
#    } else {
#        return  1;
#    } 
#
#    # Run minctensor.pl if anat mask and preprocessed minc exist
#    if (-e $anat_mask && $preproc_minc) {
#        `minctensor.pl -mask $anat_mask $preproc_minc -niakdir /opt/niak-0.6.4.1/ -outputdir $QCoutdir -octave $QCed_basename`  unless (-e $FA);
#    } else {
#        return  2;
#    }
#
#    # Run mincpik if RGB map exists. Should remove this since it will be created once pipeline finalized
#    if (-e $RGB) {
#        `mincpik -triplanar -horizontal $RGB $rgb_pic`  unless (-e $rgb_pic);
#    } else {
#        return  3;
#    }
#    
#    # Return yes if everything was successful
#    $success    = "yes";
#    return  ($success);
#}

=pod
Create a default notes file for QC summary and manual notes.
=cut
sub createNoteFile {
    my ($QC_out, $note_file, $QC_report, $reject_thresh)    =   @_;

    my ($rm_slicewise, $rm_interlace, $rm_intergradient)    =   getRejectedDirections($QC_report);

    my $count_slice     =   insertNote($note_file, $rm_slicewise,      "slicewise correlations");
    my $count_inter     =   insertNote($note_file, $rm_interlace,      "interlace correlations");
    my $count_gradient  =   insertNote($note_file, $rm_intergradient,  "gradient-wise correlations");

    my $total           =   $count_slice + $count_inter + $count_gradient;
    open    (NOTES, ">>$note_file");
    print   NOTES   "Total number of directions rejected by auto QC= $total\n";
    close   (NOTES);
    if  ($total >=  $reject_thresh) {   
        print NOTES "FAIL\n";
    } else {
        print NOTES "PASS\n";
    }

}

=pod
Get the list of directions rejected by DTI per type (i.e. slice-wise correlations, inter-lace artifacts, inter-gradient artifacts).
=cut
sub getRejectedDirections   {
    my ($QCReport)  =   @_;

    ## these are the unique directions that were rejected due to slice-wise correlations
    my $rm_slicewise    =   `cat $QCReport | grep whole | sort -k 2,2 -u | awk '{print \$2}'|tr '\n' ','`;
    ## these are the unique directions that were rejected due to inter-lace artifacts
    my $rm_interlace    =   `cat $QCReport | sed -n -e '/Interlace-wise Check Artifacts/,/================================/p' | grep '[0-9]' | sort -k 1,1 -u | awk '{print \$1}'|tr '\n' ','`;
    ## these are the unique directions that were rejected due to inter-gradient artifacts
    my $rm_intergradient=   `cat $QCReport | sed -n -e '/Inter-gradient check Artifacts::/,/================================/p' | grep '[0-9]'| sort -k 1,1 -u  | awk '{print \$1}'|tr '\n' ','`;
    
    return ($rm_slicewise, $rm_interlace, $rm_intergradient);
}

=sub
Insert into notes file the directions rejected due to a specific artifact.
=cut
sub insertNote    {
    my ($note_file, $rm_directions, $note_field)    =   @_;

    my @rm_dirs     =   split(',',$rm_directions);
    my $count_dirs  =   scalar(@rm_dirs);

    open    (NOTES, ">>$note_file");
    print   NOTES   "Directions rejected due to $note_field: @rm_dirs ($count_dirs)\n";
    close   (NOTES);

    return  ($count_dirs);
}



=pod
This function will check if all DTIPrep nrrd files were created and convert them into minc files with relevant header information inserted.
- Inputs:   - $dti_file         = raw DTI dataset that was processed through DTIPrep
            - $DTIrefs          = hash containing information about output names for all DWI datasets
            - $data_dir         = directory containing raw DTI dataset
            - $DTIPrepVersion   = DTIPrep version that was used to post process the DTI dataset
- Outputs:  - $nrrds_found set to 1 if all nrrd outputs were found. If not, $nrrds_found is not defined
            - $mincs_created set to 1 if all nrrd files were successfully converted to minc files. If not, $mincs_
created is not defined.
            - $hdrs_inserted set to 1 if all relevant header information were successfully inserted into the minc files. If not, $hdrs_inserted is not defined.
=cut
sub convert_DTIPrep_postproc_outputs {
    my ($dti_file, $DTIrefs, $data_dir, $DTIPrepVersion);

    # 1. Initialize variables
    my $tensor_nrdd     = $DTIrefs->{$dti_file}->{'Postproc'}->{'tensor_nrrd'};
    my $tensor_minc     = $DTIrefs->{$dti_file}->{'Postproc'}->{'tensor_minc'};
    my $baseline_nrrd   = $DTIrefs->{$dti_file}->{'Postproc'}->{'baseline_nrrd'};
    my $baseline_minc   = $DTIrefs->{$dti_file}->{'Postproc'}->{'baseline_minc'};
    my $rgb_nrrd        = $DTIrefs->{$dti_file}->{'Postproc'}->{'RGB_nrrd'};
    my $rgb_minc        = $DTIrefs->{$dti_file}->{'Postproc'}->{'RGB_minc'};
    my $fa_nrrd         = $DTIrefs->{$dti_file}->{'Postproc'}->{'FA_nrrd'};
    my $fa_minc         = $DTIrefs->{$dti_file}->{'Postproc'}->{'FA_minc'};
    my $md_nrrd         = $DTIrefs->{$dti_file}->{'Postproc'}->{'MD_nrrd'};
    my $md_minc         = $DTIrefs->{$dti_file}->{'Postproc'}->{'MD_minc'};
    my $idwi_nrrd       = $DTIrefs->{$dti_file}->{'Postproc'}->{'IDWI_nrrd'};
    my $idwi_minc       = $DTIrefs->{$dti_file}->{'Postproc'}->{'IDWI_minc'};

    # 2. Check that all processed outputs were created
    my $nrrds_found;
    if ((-e $tensor_nrdd) && ($baseline_nrrd) && ($rgb_nrrd) && ($fa_nrrd) && ($md_nrrd) && ($idwi_nrrd)) {
        $nrrds_found = 1;
    } else {
        $nrrds_found = undef;
    }

    # 3. Check if minc processed files were already created
    my ($mincs_created, $hdrs_inserted);
    if ((-e $tensor_minc) && ($baseline_minc) && ($rgb_minc) && ($fa_minc) && ($md_minc) && ($idwi_minc)) {
        $mincs_created   = 1;
    } else {

        # convert processed files
        my ($tensor_convert_status)  = DTI::convert_DTI($tensor_nrrd,   $tensor_minc,   'nrrd-to-minc');
        my ($baseline_convert_status)= DTI::convert_DTI($baseline_nrrd, $baseline_minc, 'nrrd-to-minc');
        my ($rgb_convert_status)     = DTI::convert_DTI($rgb_nrrd,      $rgb_minc,      'nrrd-to-minc');
        my ($fa_convert_status)      = DTI::convert_DTI($fa_nrrd,       $fa_minc,       'nrrd-to-minc');
        my ($md_convert_status)      = DTI::convert_DTI($md_nrrd,       $md_minc,       'nrrd-to-minc');
        my ($idwi_convert_status)    = DTI::convert_DTI($idwi_nrrd,     $idwi_minc,     'nrrd-to-minc');
        $mincs_created  = 1     if (($tensor_convert_status) && ($baseline_convert_status) && ($rgb_convert_status) && ($fa_convert_status) && ($md_convert_status) && ($idwi_convert_status));

        # insert mincheader information stored in raw DWI dataset (except fields with direction informations)
        my ($tensor_insert_status)   = DTI::insertMincHeader($dti_file, $data_dir, $tensor_minc,    $QCTxtReport, $DTIPrepVersion);
        my ($baseline_insert_status) = DTI::insertMincHeader($dti_file, $data_dir, $baseline_minc,  $QCTxtReport, $DTIPrepVersion);
        my ($rgb_insert_status)      = DTI::insertMincHeader($dti_file, $data_dir, $rgb_minc,       $QCTxtReport, $DTIPrepVersion);
        my ($fa_insert_status)       = DTI::insertMincHeader($dti_file, $data_dir, $fa_minc,        $QCTxtReport, $DTIPrepVersion);
        my ($md_insert_status)       = DTI::insertMincHeader($dti_file, $data_dir, $md_minc,        $QCTxtReport, $DTIPrepVersion);
        my ($idwi_insert_status)     = DTI::insertMincHeader($dti_file, $data_dir, $idwi_minc,      $QCTxtReport, $DTIPrepVersion);
        $hdrs_inserted  = 1     if (($tensor_insert_status) && ($baseline_insert_status) && ($rgb_insert_status) && ($fa_insert_status) && ($md_insert_status) && ($idwi_insert_status));

    }

    # 4. Return statements
    return ($nrrds_found, $mincs_created, $hdrs_inserted);

}

