!> @file
!! @brief Generate fixed grid files required for coupled model
!!
!! @author Denise.Worthen@noaa.gov

!> Generate fixed grid files required for coupled model using the MOM6 super grid file and ocean mask file. It creates
!! a main grid file which is then used to create subsequent files which are required to create the fix and IC
!! files required for the S2S or S2SW application.
!!
!! This executable created with this source code runs within the shell scrip cpld_gridgen.sh in ../../ush, which
!! utilizes both NCO (netCDF Operators) and ESMF command line functions. The shell script creates a run-time grid.nml
!! from grid.nml.IN
!!
!! @author Denise.Worthen@noaa.gov
!! @return 0 for success, error code otherwise.
program gen_fixgrid

  use ESMF

  use grdvars
  use inputnml
  use gengrid_kinds,     only: CL, CS, dbl_kind, real_kind, int_kind
  use angles,            only: find_angq, find_ang
  use vertices,          only: fill_vertices, fill_bottom, fill_top
  use mapped_mask,       only: make_frac_land
  use postwgts,          only: make_postwgts
  use tripolegrid,       only: write_tripolegrid
  use cicegrid,          only: write_cicegrid
  use scripgrid,         only: write_scripgrid
  use topoedits,         only: add_topoedits, apply_topoedits
  use charstrings,       only: logmsg, res, dirsrc, dirout, atmres, fv3dir, editsfile
  use charstrings,       only: maskfile, maskname, topofile, toponame, editsfile, staggerlocs, cdate, history
  use debugprint,        only: checkseam, checkxlatlon, checkpoint
  use netcdf

  implicit none

  ! local variables
  real(dbl_kind) :: dxT, dyT

  real(kind=dbl_kind), parameter :: pi = 3.14159265358979323846_dbl_kind
  real(kind=dbl_kind), parameter :: deg2rad = pi/180.0_dbl_kind

  real(real_kind),   allocatable, dimension(:,:) :: ww3dpth
  integer(int_kind), allocatable, dimension(:,:) :: ww3mask

  character(len=CL) :: fsrc, fdst, fwgt
  character(len= 2) :: cstagger

  integer :: rc,ncid,id,xtype
  integer :: i,j,k,i2,j2
  integer :: ii,jj
  integer :: localPet, nPet
  logical :: fexist = .false.

  type(ESMF_RegridMethod_Flag) :: method
  type(ESMF_VM) :: vm

  !WW3 file format for mod_def generation
  character(len= 6) :: i4fmt = '(i4.4)'
  character(len=CS) :: form1
  character(len=CS) :: form2
  character(len= 6) :: cnx

  !-------------------------------------------------------------------------
  ! Initialize esmf environment.
  !-------------------------------------------------------------------------

  call ESMF_VMGetGlobal(vm, rc=rc)
  call ESMF_Initialize(VM=vm, logkindflag=ESMF_LOGKIND_MULTI, rc=rc)
  call ESMF_VMGet(vm, localPet=localPet, peCount=nPet, rc=rc)
  if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
       line=__LINE__, file=__FILE__)) call ESMF_Finalize(endflag=ESMF_END_ABORT)
  roottask = .false.
  if (localPet == 0) roottask =.true.
  if (nPet /= 1) then
     print *,npet,' More than one task specified; Aborting '
     call ESMF_Finalize(endflag=ESMF_END_ABORT)
  end if

  !---------------------------------------------------------------------
  !
  !---------------------------------------------------------------------

  call read_inputnml('grid.nml')

  print '(a,2i6)',' output grid requested ',ni,nj
  print '(a,2i6)',' supergrid size used ', nx,ny
  print '(a)',' output grid tag '//trim(res)
  print '(a)',' supergrid source directory '//trim(dirsrc)
  print '(a)',' output grid directory '//trim(dirout)
  print '(a)',' atm resolution '//trim(atmres)
  print '(a,i6)',' fv3 tile grid size ',npx
  print '(a)',' atm mosaic directory '//trim(fv3dir)
  print '(a)',' MOM6 topography file '//trim(topofile)
  print '(a)',' MOM6 edits file '//trim(editsfile)
  print *,'editmask flag ',editmask
  print *,'debug flag ',debug
  print *,'do_postwgts flag ',do_postwgts
  print *

  call allocate_all

  call ESMF_LogWrite("Starting gen_fixgrid", ESMF_LOGMSG_INFO)
  !---------------------------------------------------------------------
  ! set up the arrays to retrieve the vertices
  !---------------------------------------------------------------------

  iVertCu = iVertCt + 1; jVertCu = jVertCt + 0
  iVertCv = iVertCt + 0; jVertCv = jVertCt + 1
  iVertBu = iVertCt + 1; jVertBu = jVertCt + 1

  print '(a8,4i6)','iVertCt ',(iVertCt(i),i=1,4)
  print '(a8,4i6)','jVertCt ',(jVertCt(i),i=1,4)
  print *
  print '(a8,4i6)','iVertCu ',(iVertCu(i),i=1,4)
  print '(a8,4i6)','jVertCu ',(jVertCu(i),i=1,4)
  print *
  print '(a8,4i6)','iVertCv ',(iVertCv(i),i=1,4)
  print '(a8,4i6)','jVertCv ',(jVertCv(i),i=1,4)
  print *
  print '(a8,4i6)','iVertBu ',(iVertBu(i),i=1,4)
  print '(a8,4i6)','jVertBu ',(jVertBu(i),i=1,4)
  print *

  latCt_vert = -9999.0 ; lonCt_vert = -9999.0
  latCu_vert = -9999.0 ; lonCu_vert = -9999.0
  latCv_vert = -9999.0 ; lonCv_vert = -9999.0
  latBu_vert = -9999.0 ; lonBu_vert = -9999.0

  !---------------------------------------------------------------------
  ! read the MOM6 land mask
  !---------------------------------------------------------------------

  fsrc = trim(dirsrc)//'/'//trim(maskfile)

  rc = nf90_open(fsrc, nf90_nowrite, ncid)
  print '(a)', 'reading ocean mask from '//trim(fsrc)
  if(rc .ne. 0)print '(a)', 'nf90_open = '//trim(nf90_strerror(rc))

  wet4 = 0.0; wet8 = 0.0
  rc = nf90_inq_varid(ncid,  trim(maskname), id)
  rc = nf90_inquire_variable(ncid, id, xtype=xtype)
  if(xtype .eq. 5)rc = nf90_get_var(ncid,      id,  wet4)
  if(xtype .eq. 6)rc = nf90_get_var(ncid,      id,  wet8)
  rc = nf90_close(ncid)

  if(xtype.eq. 6)wet4 = real(wet8,4)

  !print *,minval(wet8),maxval(wet8)
  !print *,minval(wet4),maxval(wet4)

  !---------------------------------------------------------------------
  ! read the MOM6 depth file
  !---------------------------------------------------------------------

  fsrc = trim(dirsrc)//'/'//trim(topofile)

  rc = nf90_open(fsrc, nf90_nowrite, ncid)
  print '(a)', 'reading ocean topography from '//trim(fsrc)
  if(rc .ne. 0)print '(a)', 'nf90_open = '//trim(nf90_strerror(rc))

  dp4 = 0.0; dp8 = 0.0
  rc = nf90_inq_varid(ncid,  trim(toponame), id)
  rc = nf90_inquire_variable(ncid, id, xtype=xtype)
  if(xtype .eq. 5)rc = nf90_get_var(ncid,      id,  dp4)
  if(xtype .eq. 6)rc = nf90_get_var(ncid,      id,  dp8)
  rc = nf90_close(ncid)

  if(xtype.eq. 6)dp4 = real(dp8,4)

  !print *,minval(dp8),maxval(dp8)
  !print *,minval(dp4),maxval(dp4)

  if(editmask)then
     !---------------------------------------------------------------------
     !  apply topoedits run time mask changes if required for this config
     !---------------------------------------------------------------------

     if(trim(editsfile)  == 'none')then
        print '(a)', 'Need a valid editsfile to make mask edits '
        stop
     end if

     fsrc = trim(dirsrc)//'/'//trim(editsfile)
     fdst = trim(dirout)//'/'//'ufs.'//trim(editsfile)
     call add_topoedits(fsrc,fdst)
  endif

  !---------------------------------------------------------------------
  ! MOM6 reads the depth file, applies the topo edits and then adjusts
  ! depth using masking_depth and min/max depth. This call mimics
  ! MOM6 routines apply_topography_edits_from_file and limit_topography
  !---------------------------------------------------------------------

  fsrc = trim(dirsrc)//'/'//trim(editsfile)
  if(editmask)fsrc = trim(dirout)//'/'//'ufs.'//trim(editsfile)
  call apply_topoedits(fsrc)

  !---------------------------------------------------------------------
  ! read MOM6 supergrid file
  !---------------------------------------------------------------------

  fsrc = trim(dirsrc)//'/'//'ocean_hgrid.nc'

  rc = nf90_open(fsrc, nf90_nowrite, ncid)
  print '(a)', 'reading supergrid from '//trim(fsrc)
  if(rc .ne. 0)print '(a)', 'nf90_open = '//trim(nf90_strerror(rc))

  rc = nf90_inq_varid(ncid, 'x', id)  !lon
  rc = nf90_get_var(ncid,    id,  x)

  rc = nf90_inq_varid(ncid, 'y', id)  !lat
  rc = nf90_get_var(ncid,    id,  y)

  rc = nf90_inq_varid(ncid, 'dx', id)
  rc = nf90_get_var(ncid,     id, dx)

  rc = nf90_inq_varid(ncid, 'dy', id)
  rc = nf90_get_var(ncid,     id, dy)

  rc = nf90_close(ncid)
  !print *,'super grid size ',size(y,1),size(y,2)
  !print *,'max lat in super grid ',maxval(y)
  sg_maxlat = maxval(y)

  !---------------------------------------------------------------------
  ! find the angle on corners---this requires the supergrid
  !---------------------------------------------------------------------

  call find_angq

  !---------------------------------------------------------------------
  ! fill grid variables
  !---------------------------------------------------------------------

  do j = 1,nj
     do i = 1,ni
        i2 = 2*i ; j2 = 2*j
        !deg->rad
        ulon(i,j) =     x(i2,j2)*deg2rad
        ulat(i,j) =     y(i2,j2)*deg2rad
        !in rad already
        angle(i,j) = -angq(i2,j2)
        !m->cm
        htn(i,j) = (dx(i2-1,j2) + dx(i2,j2))*100._dbl_kind
        hte(i,j) = (dy(i2,j2-1) + dy(i2,j2))*100._dbl_kind
        !deg
        lonBu(i,j) =     x(i2,j2)
        latBu(i,j) =     y(i2,j2)
        !deg
        lonCt(i,j) =     x(i2-1,j2-1)
        lonCu(i,j) =     x(i2,  j2-1)
        lonCv(i,j) =     x(i2-1,j2  )
        !deg
        latCt(i,j) =     y(i2-1,j2-1)
        latCu(i,j) =     y(i2,  j2-1)
        latCv(i,j) =     y(i2-1,j2  )
        !m2
        dxT = dx(i2-1,j2-1) + dx(i2,j2-1)
        dyT = dy(i2-1,j2-1) + dy(i2-1,j2)
        areaCt(i,j) = dxT*dyT
     enddo
  enddo

  !---------------------------------------------------------------------
  ! find the angle on centers---this does not requires the supergrid
  !---------------------------------------------------------------------

  call find_ang
  print *,'ANGLET ',minval(anglet),maxval(anglet)
  print *,'ANGLE  ',minval(angle),maxval(angle)

  !---------------------------------------------------------------------
  ! For the 1/4deg grid, hte at j=720 and j = 1440 is identically=0.0 for
  ! j > 840 (64.0N). These are land points, but since CICE uses hte to
  ! generate remaining variables, setting them to zero will cause problems
  ! For 1deg grid, hte at ni/2 and ni are very small O~10-12, so test for
  ! hte < 1.0
  !---------------------------------------------------------------------

  write(logmsg,'(a,2e12.5)')'min vals of hte at folds ', &
       minval(hte(ni/2,:)),minval(hte(ni,:))
  print '(a)',trim(logmsg)
  do j = 1,nj
     ii = ni/2
     if(hte(ii,j) .le. 1.0)hte(ii,j) = 0.5*(hte(ii-1,j) + hte(ii+1,j))
     ii = ni
     if(hte(ii,j) .le. 1.0)hte(ii,j) = 0.5*(hte(ii-1,j) + hte(   1,j))
  enddo
  write(logmsg,'(a,2e12.5)')'min vals of hte at folds ', &
       minval(hte(ni/2,:)),minval(hte(ni,:))
  print '(a)',trim(logmsg)

  !---------------------------------------------------------------------
  !
  !---------------------------------------------------------------------

  where(lonCt .lt. 0.0)lonCt = lonCt + 360._dbl_kind
  where(lonCu .lt. 0.0)lonCu = lonCu + 360._dbl_kind
  where(lonCv .lt. 0.0)lonCv = lonCv + 360._dbl_kind
  where(lonBu .lt. 0.0)lonBu = lonBu + 360._dbl_kind

  !---------------------------------------------------------------------
  ! some basic error checking
  ! find the i-th index of the poles at j= nj
  ! the corner points must lie on the pole
  !---------------------------------------------------------------------

  ipole = -1
  j = nj
  do i = 1,ni/2
     if(latBu(i,j) .eq. sg_maxlat)ipole(1) = i
  enddo
  do i = ni/2+1,ni
     if(latBu(i,j) .eq. sg_maxlat)ipole(2) = i
  enddo
  write(logmsg,'(a,2i6,2f12.2)')'poles found at i = ',ipole,latBu(ipole(1),nj), &
       latBu(ipole(2),nj)
  print '(a)',trim(logmsg)

  if(debug)call checkseam

  do i = 1,ni
     i2 = ipole(2)+(ipole(1)-i)+1
     xlonCt(i) = lonCt(i2,nj)
     xlatCt(i) = latCt(i2,nj)
  enddo

  do i = 1,ni
     i2 = ipole(2)+(ipole(1)-i)
     if(i2 .lt. 1)i2 = ni
     xlonCu(i) = lonCu(i2,nj)
     xlatCu(i) = latCu(i2,nj)
  enddo

  if(debug)call checkxlatlon

  !approx lat at grid bottom
  do i = 1,ni
     dlatBu(i) = latBu(i,1) + 2.0*(latCu(i,1) - latBu(i,1))
     dlatCv(i) = latCt(i,1) + 2.0*(latCt(i,1) - latCv(i,1))
  enddo

  !---------------------------------------------------------------------
  ! fill grid vertices variables
  !---------------------------------------------------------------------

  !Ct and Cu grids align in j
  call fill_vertices(2,nj  , iVertCt,jVertCt, latBu,lonBu, latCt_vert,lonCt_vert)
  call           fill_bottom(iVertCt,jVertCt, latBu,lonBu, latCt_vert,lonCt_vert,dlatBu)

  call fill_vertices(2,nj  , iVertCu,jVertCu, latCv,lonCv, latCu_vert,lonCu_vert)
  call           fill_bottom(iVertCu,jVertCu, latCv,lonCv, latCu_vert,lonCu_vert,dlatCv)

  !Cv and Bu grids align in j
  call fill_vertices(1,nj-1, iVertCv,jVertCv, latCu,lonCu, latCv_vert,lonCv_vert)
  call              fill_top(iVertCv,jVertCv, latCu,lonCu, latCv_vert,lonCv_vert, xlatCu, xlonCu)

  call fill_vertices(1,nj-1, iVertBu,jVertBu, latCt,lonCt, latBu_vert,lonBu_vert)
  call              fill_top(iVertBu,jVertBu, latCt,lonCt, latBu_vert,lonBu_vert, xlatCt, xlonCt)

  if(debug)call checkpoint

  if(minval(latCt_vert) .lt. -1.e3)stop
  if(minval(lonCt_vert) .lt. -1.e3)stop
  if(minval(latCu_vert) .lt. -1.e3)stop
  if(minval(lonCu_vert) .lt. -1.e3)stop
  if(minval(latCv_vert) .lt. -1.e3)stop
  if(minval(lonCv_vert) .lt. -1.e3)stop
  if(minval(latBu_vert) .lt. -1.e3)stop
  if(minval(lonBu_vert) .lt. -1.e3)stop
  deallocate(xlonCt, xlatCt, xlonCu, xlatCu, dlatBu, dlatCv)

  !---------------------------------------------------------------------
  ! write out grid file files
  !---------------------------------------------------------------------

  ! create a history attribute
  call date_and_time(date=cdate)
  history = 'created on '//trim(cdate)//' from '//trim(fsrc)

  ! write fix grid
  fdst = trim(dirout)//'/'//'tripole.mx'//trim(res)//'.nc'
  call write_tripolegrid(trim(fdst))

  ! write cice grid
  fdst = trim(dirout)//'/'//'grid_cice_NEMS_mx'//trim(res)//'.nc'
  call write_cicegrid(trim(fdst))
  deallocate(ulon, ulat, htn, hte)
  ! write scrip grids; only the Ct is required, the remaining
  ! staggers are used only in the postweights generation
  do k = 1,nv
     cstagger = trim(staggerlocs(k))
     fdst = trim(dirout)//'/'//trim(cstagger)//'.mx'//trim(res)//'_SCRIP.nc'
     logmsg = 'creating SCRIP file '//trim(fdst)
     print '(a)',trim(logmsg)
     call write_scripgrid(trim(fdst),trim(cstagger))
  end do
  deallocate(latCv_vert, lonCv_vert)
  deallocate(latCu_vert, lonCu_vert)
  deallocate(latBu_vert, lonBu_vert)

  ! write SCRIP file with land mask, used for mapped ocean mask
  ! and  mesh creation
  cstagger = trim(staggerlocs(1))
  fdst= trim(dirout)//'/'//trim(cstagger)//'.mx'//trim(res)//'_SCRIP_land.nc'
  logmsg = 'creating SCRIP file '//trim(fdst)
  print '(a)',trim(logmsg)
  call write_scripgrid(trim(fdst),trim(cstagger),imask=int(wet4))
  deallocate(latCt_vert, lonCt_vert)

  !---------------------------------------------------------------------
  ! write lat,lon,depth and mask arrays required by ww3 in creating
  ! mod_def file
  !---------------------------------------------------------------------

  write(cnx,i4fmt)nx
  write(form1,'(a)')'('//trim(cnx)//'f14.8)'
  write(form2,'(a)')'('//trim(cnx)//'i2)'

  allocate(ww3mask(1:ni,1:nj)); ww3mask = wet4
  allocate(ww3dpth(1:ni,1:nj)); ww3dpth = dp4

  where(latCt .ge. maximum_lat)ww3mask = 3
  !close last row
  ww3mask(:,nj) = 3

  open(unit=21,file=trim(dirout)//'/'//'ww3.mx'//trim(res)//'_x.inp',form='formatted')
  open(unit=22,file=trim(dirout)//'/'//'ww3.mx'//trim(res)//'_y.inp',form='formatted')
  open(unit=23,file=trim(dirout)//'/'//'ww3.mx'//trim(res)//'_bottom.inp',form='formatted')
  open(unit=24,file=trim(dirout)//'/'//'ww3.mx'//trim(res)//'_mapsta.inp',form='formatted')
  ! cice0 .ne. cicen requires obstruction map, should be initialized as zeros (w3grid,ln3032)
  open(unit=25,file=trim(dirout)//'/'//'ww3.mx'//trim(res)//'_obstr.inp',form='formatted')

  do j = 1,nj
     write( 21,trim(form1))lonCt(:,j)
     write( 22,trim(form1))latCt(:,j)
  end do
  do j = 1,nj
     write( 23,trim(form1))ww3dpth(:,j)
     write( 24,trim(form2))ww3mask(:,j)
     !'obsx' and 'obsy' arrays ???
     write( 25,trim(form2))ww3mask(:,j)*0
     write( 25,trim(form2))ww3mask(:,j)*0
  end do

  close(21); close(22); close(23); close(24); close(25)
  deallocate(ww3mask); deallocate(ww3dpth)
  deallocate(wet4, wet8)

  !---------------------------------------------------------------------
  ! use ESMF regridding to produce mapped ocean mask; first generate
  ! conservative regrid weights from ocean to tiles; then generate the
  ! tiled files containing the mapped ocean mask
  !---------------------------------------------------------------------

  method=ESMF_REGRIDMETHOD_CONSERVE
  fsrc = trim(dirout)//'/'//'Ct.mx'//trim(res)//'_SCRIP_land.nc'
  fdst = trim(fv3dir)//'/'//trim(atmres)//'/'//trim(atmres)//'_mosaic.nc'
  fwgt = trim(dirout)//'/'//'Ct.mx'//trim(res)//'.to.'//trim(atmres)//'.nc'
  logmsg = 'creating weight file '//trim(fwgt)
  print '(a)',trim(logmsg)

  call ESMF_RegridWeightGen(srcFile=trim(fsrc),dstFile=trim(fdst),         &
       weightFile=trim(fwgt), regridmethod=method,                         &
       unmappedaction=ESMF_UNMAPPEDACTION_IGNORE, ignoreDegenerate=.true., &
       netcdf4fileFlag=.true., tileFilePath=trim(fv3dir)//'/'//trim(atmres)//'/', rc=rc)
  if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
       line=__LINE__, file=__FILE__)) call ESMF_Finalize(endflag=ESMF_END_ABORT)

  logmsg = 'creating mapped ocean mask for '//trim(atmres)
  print '(a)',trim(logmsg)
  call make_frac_land(trim(fsrc), trim(fwgt))

  !---------------------------------------------------------------------
  ! use ESMF to find the tripole:tripole weights for creation
  ! of CICE ICs; the source grid is always mx025; don't create this
  ! file if destination is also mx025
  !---------------------------------------------------------------------

  if(trim(res) .ne. '025') then
     fsrc = trim(dirout)//'/'//'Ct.mx025_SCRIP.nc'
     inquire(FILE=trim(fsrc), EXIST=fexist)
     if (fexist ) then
        method=ESMF_REGRIDMETHOD_NEAREST_STOD
        fdst = trim(dirout)//'/'//'Ct.mx'//trim(res)//'_SCRIP.nc'
        fwgt = trim(dirout)//'/'//'tripole.mx025.Ct.to.mx'//trim(res)//'.Ct.neareststod.nc'
        logmsg = 'creating weight file '//trim(fwgt)
        print '(a)',trim(logmsg)

        call ESMF_RegridWeightGen(srcFile=trim(fsrc),dstFile=trim(fdst), &
             weightFile=trim(fwgt), regridmethod=method,                 &
             ignoreDegenerate=.true., unmappedaction=ESMF_UNMAPPEDACTION_IGNORE, rc=rc)
        if (ESMF_LogFoundError(rcToCheck=rc, msg=ESMF_LOGERR_PASSTHRU, &
             line=__LINE__, file=__FILE__)) call ESMF_Finalize(endflag=ESMF_END_ABORT)
     else
        logmsg = 'ERROR: '//trim(fsrc)//' is required to generate tripole:triple weights'
        print '(a)',trim(logmsg)
        stop
     end if
  end if

  !---------------------------------------------------------------------
  !
  !---------------------------------------------------------------------

  if(do_postwgts)call make_postwgts

  !---------------------------------------------------------------------
  ! clean up
  !---------------------------------------------------------------------

  deallocate(x,y, angq, dx, dy, xsgp1, ysgp1)
  deallocate(areaCt, anglet, angle)
  deallocate(latCt, lonCt)
  deallocate(latCv, lonCv)
  deallocate(latCu, lonCu)
  deallocate(latBu, lonBu)

end program gen_fixgrid
