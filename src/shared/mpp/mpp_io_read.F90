module mpp_io_read_mod
#include <fms_platform.h>

use mpp_mod,           only : mpp_error, FATAL, NOTE, mpp_transmit, ALL_PES, lowercase, mpp_root_pe
use mpp_domains_mod,   only : domain2D, mpp_get_data_domain, mpp_get_compute_domain, mpp_get_global_domain
use mpp_parameter_mod, only : MPP_SINGLE, MPP_NETCDF, MPP_MULTI
use mpp_datatype_mod,  only : axistype, fieldtype
use mpp_data_mod,      only : mpp_file, mpp_io_stack, mpp_io_stack_size, verbose=>verbose_mpp_io
use mpp_data_mod,      only : module_is_initialized=>mpp_io_is_initialized, default_field
use mpp_data_mod,      only : default_att, default_axis, pe, npes
use mpp_io_util_mod,   only : mpp_io_set_stack_size
use mpp_io_misc_mod,   only : netcdf_err

implicit none
private


character(len=128) :: version= &
     '$Id: mpp_io_read.F90,v 12.0 2005/04/14 17:58:36 fms Exp $'
character(len=128) :: tagname= &
     '$Name: lima $'

public :: mpp_read, mpp_read_meta, mpp_get_tavg_info

! <INTERFACE NAME="mpp_read">
!   <OVERVIEW>
!     Read from an open file.
!   </OVERVIEW>
!   <DESCRIPTION>
!      <TT>mpp_read</TT> is used to read data to the file on an I/O unit
!      using the file parameters supplied by <LINK
!      SRC="#mpp_open"><TT>mpp_open</TT></LINK>. There are two
!      forms of <TT>mpp_read</TT>, one to read
!      distributed field data, and one to read non-distributed field
!      data. <I>Distributed</I> data refer to arrays whose two
!      fastest-varying indices are domain-decomposed. Distributed data must
!      be 2D or 3D (in space). Non-distributed data can be 0-3D.
!
!      The <TT>data</TT> argument for distributed data is expected by
!      <TT>mpp_read</TT> to contain data specified on the <I>data</I> domain,
!      and will read the data belonging to the <I>compute</I> domain,
!      fetching data as required by the parallel I/O <LINK
!      SRC="#modes">mode</LINK> specified in the <TT>mpp_open</TT> call. This
!      is consistent with our definition of <LINK
!      SRC="http:mpp_domains.html#domains">domains</LINK>, where all arrays are
!      expected to be dimensioned on the data domain, and all operations
!      performed on the compute domain.
!   </DESCRIPTION>
!   <TEMPLATE>
!     call mpp_read( unit, field, data, time_index )
!   </TEMPLATE>
!   <TEMPLATE>
!     call mpp_read( unit, field, domain, data, time_index )
!   </TEMPLATE>
!  <IN NAME="unit"></IN>
!  <IN NAME="field"></IN>
!  <INOUT NAME="data"></INOUT>
!  <IN NAME="domain"></IN>
!  <IN NAME="time_index">
!     time_index is an optional argument. It is to be omitted if the
!     field was defined not to be a function of time. Results are
!     unpredictable if the argument is supplied for a time- independent
!     field, or omitted for a time-dependent field.
!  </IN>
!  <NOTE>
!     The type of read performed by <TT>mpp_read</TT> depends on
!     the file characteristics on the I/O unit specified at the <LINK
!     SRC="#mpp_open"><TT>mpp_open</TT></LINK> call. Specifically, the
!     format of the input data (e.g netCDF or IEEE) and the
!     <TT>threading</TT> flags, etc., can be changed there, and
!     require no changes to the <TT>mpp_read</TT>
!     calls. (<TT>fileset</TT> = MPP_MULTI is not supported by
!     <TT>mpp_read</TT>; IEEE is currently not supported).
!
!     Packed variables are unpacked using the <TT>scale</TT> and
!     <TT>add</TT> attributes.
!
!     <TT>mpp_read_meta</TT> must be called prior to calling <TT>mpp_read.</TT>
!  </NOTE>
! </INTERFACE>
  interface mpp_read
     module procedure mpp_read_2ddecomp_r2d
     module procedure mpp_read_2ddecomp_r3d
     module procedure mpp_read_r0D
     module procedure mpp_read_r1D
     module procedure mpp_read_r2D
     module procedure mpp_read_r3D
  end interface

#ifdef use_netCDF
#include <netcdf.inc>
#endif

contains

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!                                                                      !
!                               MPP_READ                               !
!                                                                      !
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

#define MPP_READ_2DDECOMP_2D_ mpp_read_2ddecomp_r2d
#define MPP_READ_2DDECOMP_3D_ mpp_read_2ddecomp_r3d
#define MPP_TYPE_ real
#include <mpp_read_2Ddecomp.h>

    subroutine read_record( unit, field, nwords, data, time_level, domain )
!routine that is finally called by all mpp_read routines to perform the read
!a non-netCDF record contains:
!      field ID
!      a set of 4 coordinates (is:ie,js:je) giving the data subdomain
!      a timelevel and a timestamp (=NULLTIME if field is static)
!      3D real data (stored as 1D)
!if you are using direct access I/O, the RECL argument to OPEN must be large enough for the above
!in a global direct access file, record position on PE is given by %record.

!Treatment of timestamp:
!   We assume that static fields have been passed without a timestamp.
!   Here that is converted into a timestamp of NULLTIME.
!   For non-netCDF fields, field is treated no differently, but is written
!   with a timestamp of NULLTIME. There is no check in the code to prevent
!   the user from repeatedly writing a static field.

      integer, intent(in) :: unit, nwords
      type(fieldtype), intent(in) :: field
      real, intent(inout) :: data(nwords)
      integer, intent(in), optional  :: time_level
      type(domain2D), intent(in), optional :: domain
      integer, dimension(size(field%axes(:))) :: start, axsiz
      real :: time

      logical :: newtime
      integer :: subdomain(4), tlevel
      
      integer(SHORT_KIND) :: i2vals(nwords)
!#ifdef __sgi
      integer(INT_KIND) :: ivals(nwords)
      real(FLOAT_KIND) :: rvals(nwords)
!#else
!      integer :: ivals(nwords)
!      real :: rvals(nwords)
!#endif

      real(DOUBLE_KIND) :: r8vals(nwords)
      
      integer :: i, error, is, ie, js, je, isg, ieg, jsg, jeg
      
#ifdef use_CRI_pointers
      pointer( ptr1, i2vals )
      pointer( ptr2, ivals )
      pointer( ptr3, rvals )
      pointer( ptr4, r8vals )
      
      if (mpp_io_stack_size < 4*nwords) call mpp_io_set_stack_size(4*nwords)
      
      ptr1 = LOC(mpp_io_stack(1))
      ptr2 = LOC(mpp_io_stack(nwords+1))
      ptr3 = LOC(mpp_io_stack(2*nwords+1))
      ptr4 = LOC(mpp_io_stack(3*nwords+1))
#endif
      if (.not.PRESENT(time_level)) then
          tlevel = 0
      else
          tlevel = time_level
      endif

#ifdef use_netCDF
      if( .NOT.module_is_initialized )call mpp_error( FATAL, 'READ_RECORD: must first call mpp_io_init.' )
      if( .NOT.mpp_file(unit)%opened )call mpp_error( FATAL, 'READ_RECORD: invalid unit number.' )
      if( mpp_file(unit)%threading.EQ.MPP_SINGLE .AND. pe.NE.mpp_root_pe() )return
      if( mpp_file(unit)%fileset.EQ.MPP_MULTI )call mpp_error( FATAL, 'READ_RECORD: multiple filesets not supported for MPP_READ' )

      if( .NOT.mpp_file(unit)%initialized ) call mpp_error( FATAL, 'MPP_READ: must first call mpp_read_meta.' )



      if( verbose )print '(a,2i3,2i5)', 'MPP_READ: PE, unit, %id, %time_level =',&
           pe, unit, mpp_file(unit)%id, tlevel

      if( mpp_file(unit)%format.EQ.MPP_NETCDF )then
!define netCDF data block to be read:
!  time axis: START = time level
!             AXSIZ = 1
!  space axis: if there is no domain info
!              START = 1
!              AXSIZ = field%size(axis)
!          if there IS domain info:
!              start of domain is compute%start_index for multi-file I/O
!                                 global%start_index for all other cases
!              this number must be converted to 1 for NF_GET_VAR
!                  (netCDF fortran calls are with reference to 1),
!          So, START = compute%start_index - <start of domain> + 1
!              AXSIZ = usually compute%size
!          However, if compute%start_index-compute%end_index+1.NE.compute%size,
!              we assume that the call is passing a subdomain.
!              To pass a subdomain, you must pass a domain2D object that satisfies the following:
!                  global%start_index must contain the <start of domain> as defined above;
!                  the data domain and compute domain must refer to the subdomain being passed.
!              In this case, START = compute%start_index - <start of domain> + 1
!                            AXSIZ = compute%start_index - compute%end_index + 1
! NOTE: passing of subdomains will fail for multi-PE single-threaded I/O,
!       since that attempts to gather all data on PE 0.
          start = 1
          do i = 1,size(field%axes(:))
             axsiz(i) = field%size(i)
             if( field%axes(i)%did.EQ.field%time_axis_index )start(i) = tlevel
          end do
          if( PRESENT(domain) )then
              call mpp_get_compute_domain( domain, is,  ie,  js,  je  )
              call mpp_get_global_domain ( domain, isg, ieg, jsg, jeg )
              axsiz(1) = ie-is+1
              axsiz(2) = je-js+1
              if( npes.GT.1 .AND. mpp_file(unit)%fileset.EQ.MPP_SINGLE )then
                  start(1) = is - isg + 1
                  start(2) = js - jsg + 1
              else
                  if( ie-is+1.NE.ie-is+1 )then
                      start(1) = is - isg + 1
                      axsiz(1) = ie - is + 1 
                  end if
                  if( je-js+1.NE.je-js+1 )then
                      start(2) = js - jsg + 1
                      axsiz(2) = je - js + 1 
                  end if
              end if  
          end if  
              
          if( verbose )print '(a,2i3,i6,12i4)', 'READ_RECORD: PE, unit, nwords, start, axsiz=', pe, unit, nwords, start, axsiz
          
          select case (field%type)
             case(NF_BYTE)
! use type conversion
                call mpp_error( FATAL, 'MPP_READ: does not support NF_BYTE packing' )
             case(NF_SHORT)
                error = NF_GET_VARA_INT2  ( mpp_file(unit)%ncid, field%id, start, axsiz, i2vals )
                call netcdf_err( error, mpp_file(unit), field=field )
                data(:)=i2vals(:)*field%scale + field%add
             case(NF_INT)
                error = NF_GET_VARA_INT   ( mpp_file(unit)%ncid, field%id, start, axsiz, ivals  )
                call netcdf_err( error, mpp_file(unit), field=field )
                data(:)=ivals(:)*field%scale + field%add
             case(NF_FLOAT)
                error = NF_GET_VARA_REAL  ( mpp_file(unit)%ncid, field%id, start, axsiz, rvals  )
                call netcdf_err( error, mpp_file(unit), field=field )
                data(:)=rvals(:)*field%scale + field%add
             case(NF_DOUBLE)
                error = NF_GET_VARA_DOUBLE( mpp_file(unit)%ncid, field%id, start, axsiz, r8vals )
                call netcdf_err( error, mpp_file(unit), field=field )
                data(:)=r8vals(:)*field%scale + field%add
             case default
                call mpp_error( FATAL, 'MPP_READ: invalid pack value' )
          end select
      else                      !non-netCDF
!subdomain contains (/is,ie,js,je/)
          call mpp_error( FATAL, 'Currently dont support non-NetCDF mpp read' )
          
      end if
#else 
      call mpp_error( FATAL, 'MPP_READ currently requires use_netCDF option' )
#endif
      return
    end subroutine read_record


! <SUBROUTINE NAME="mpp_read_r3D" INTERFACE="mpp_read">
!   <IN NAME="unit" TYPE="integer"></IN>
!   <IN NAME="field" TYPE="type(fieldtype)"></IN>
!   <INOUT NAME="data" TYPE="real" DIM="(:,:,:)"></INOUT>
!   <IN NAME="tindex" TYPE="integer"></IN>
! </SUBROUTINE>
    subroutine mpp_read_r3D( unit, field, data, tindex)
      integer, intent(in) :: unit
      type(fieldtype), intent(in) :: field
      real, intent(inout) :: data(:,:,:)
      integer, intent(in), optional :: tindex
      
      call read_record( unit, field, size(data(:,:,:)), data, tindex )
    end subroutine mpp_read_r3D
      
    subroutine mpp_read_r2D( unit, field, data, tindex )
      integer, intent(in) :: unit
      type(fieldtype), intent(in) :: field
      real, intent(inout) :: data(:,:)
      integer, intent(in), optional :: tindex
      
      call read_record( unit, field, size(data(:,:)), data, tindex )
    end subroutine mpp_read_r2D
      
    subroutine mpp_read_r1D( unit, field, data, tindex )
      integer, intent(in) :: unit
      type(fieldtype), intent(in) :: field
      real, intent(inout) :: data(:)
      integer, intent(in), optional :: tindex
      
      call read_record( unit, field, size(data(:)), data, tindex )
    end subroutine mpp_read_r1D
      
    subroutine mpp_read_r0D( unit, field, data, tindex )
      integer, intent(in) :: unit
      type(fieldtype), intent(in) :: field
      real, intent(inout) :: data
      integer, intent(in), optional :: tindex
      real, dimension(1) :: data_tmp
      
      data_tmp(1)=data
      call read_record( unit, field, 1, data_tmp, tindex )
      data=data_tmp(1)
    end subroutine mpp_read_r0D

! <SUBROUTINE NAME="mpp_read_meta">

!   <OVERVIEW>
!     Read metadata.
!   </OVERVIEW>
!   <DESCRIPTION>
!     This routine is used to read the <LINK SRC="#metadata">metadata</LINK>
!     describing the contents of a file. Each file can contain any number of
!     fields, which are functions of 0-3 space axes and 0-1 time axes. (Only
!     one time axis can be defined per file). The basic metadata defined <LINK
!     SRC="#metadata">above</LINK> for <TT>axistype</TT> and
!     <TT>fieldtype</TT> are stored in <TT>mpp_io_mod</TT> and
!     can be accessed outside of <TT>mpp_io_mod</TT> using calls to
!     <TT>mpp_get_info</TT>, <TT>mpp_get_atts</TT>,
!     <TT>mpp_get_vars</TT> and
!     <TT>mpp_get_times</TT>.
!   </DESCRIPTION>
!   <TEMPLATE>
!     call mpp_read_meta(unit)
!   </TEMPLATE>
!   <IN NAME="unit" TYPE="integer"> </IN>
!   <NOTE>
!     <TT>mpp_read_meta</TT> must be called prior to <TT>mpp_read</TT>.
!   </NOTE>
! </SUBROUTINE>
    subroutine mpp_read_meta(unit)
!   
! read file attributes including dimension and variable attributes
! and store in filetype structure.  All of the file information
! with the exception of the (variable) data is stored.  Attributes
! are supplied to the user by get_info,get_atts,get_axes and get_fields
!
! every PE is eligible to call mpp_read_meta
!
!     integer, parameter :: MAX_DIMVALS = 100000
      integer, parameter :: MAX_DIMVALS = 250000
      integer, intent(in) :: unit
      
      integer         :: ncid,ndim,nvar_total,natt,recdim,nv,nvar,len
      integer :: error,i,j
      integer         :: type,nvdims,nvatts, dimid
      integer, allocatable, dimension(:) :: dimids
      type(axistype) , allocatable, dimension(:) :: Axis
      character(len=128) :: name, attname, unlimname, attval
      logical :: isdim
      
      integer(SHORT_KIND) :: i2vals(MAX_DIMVALS)
!#ifdef __sgi
      integer(INT_KIND) :: ivals(MAX_DIMVALS)
      real(FLOAT_KIND)  :: rvals(MAX_DIMVALS)
!#else
!      integer :: ivals(MAX_DIMVALS)
!      real    :: rvals(MAX_DIMVALS)
!#endif
      real(DOUBLE_KIND) :: r8vals(MAX_DIMVALS)
      
#ifdef use_netCDF

      if( mpp_file(unit)%format.EQ.MPP_NETCDF )then
        ncid = mpp_file(unit)%ncid
        error = NF_INQ(ncid,ndim, nvar_total,&
                      natt, recdim);call netcdf_err( error, mpp_file(unit) )
                      
                      
        mpp_file(unit)%ndim = ndim
        mpp_file(unit)%natt = natt
        mpp_file(unit)%recdimid = recdim
!       
! if no recdim exists, recdimid = -1
! variable id of unlimdim and length
!
        if( recdim.NE.-1 )then
           error = NF_INQ_DIM( ncid, recdim, unlimname, mpp_file(unit)%time_level )
           call netcdf_err( error, mpp_file(unit) )
           error = NF_INQ_VARID( ncid, unlimname, mpp_file(unit)%id )
           call netcdf_err( error, mpp_file(unit), string='Field='//unlimname )
        else
           mpp_file(unit)%time_level = -1 ! set to zero so mpp_get_info returns ntime=0 if no time axis present
        endif
           
        allocate(mpp_file(unit)%Att(natt))
        allocate(Axis(ndim))
        allocate(dimids(ndim))
        allocate(mpp_file(unit)%Axis(ndim))
        
!       
! initialize fieldtype and axis type
!


        do i=1,ndim
           Axis(i) = default_axis
           mpp_file(unit)%Axis(i) = default_axis
        enddo
           
        do i=1,natt
           mpp_file(unit)%Att(i) = default_att
        enddo
           
!       
! assign global attributes
!
        do i=1,natt
           error=NF_INQ_ATTNAME(ncid,NF_GLOBAL,i,name);call netcdf_err( error, mpp_file(unit), string=' Global attribute error.' )
           error=NF_INQ_ATT(ncid,NF_GLOBAL,trim(name),type,len);call netcdf_err( error, mpp_file(unit), string=' Attribute='//name )
           mpp_file(unit)%Att(i)%name = name
           mpp_file(unit)%Att(i)%len = len
           mpp_file(unit)%Att(i)%type = type
!          
!  allocate space for att data and assign
!
           select case (type)
              case (NF_CHAR)
                 if (len.gt.512) then
                    call mpp_error(NOTE,'GLOBAL ATT too long - not reading this metadata')
                    len=7
                    mpp_file(unit)%Att(i)%len=len
                    mpp_file(unit)%Att(i)%catt = 'unknown'
                 else
                     error=NF_GET_ATT_TEXT(ncid,NF_GLOBAL,name,mpp_file(unit)%Att(i)%catt)
                     call netcdf_err( error, mpp_file(unit), attr=mpp_file(unit)%att(i) )
                     if (verbose.and.pe == 0) print *, 'GLOBAL ATT ',trim(name),' ',mpp_file(unit)%Att(i)%catt(1:len)
                 endif
!                    
! store integers in float arrays
!
              case (NF_SHORT)
                 allocate(mpp_file(unit)%Att(i)%fatt(len))
                 error=NF_GET_ATT_INT2(ncid,NF_GLOBAL,name,i2vals)
                 call netcdf_err( error, mpp_file(unit), attr=mpp_file(unit)%att(i) )
                 if( verbose .and. pe == 0 )print *, 'GLOBAL ATT ',trim(name),' ',i2vals(1:len)
                 mpp_file(unit)%Att(i)%fatt(1:len)=i2vals(1:len)
              case (NF_INT)
                 allocate(mpp_file(unit)%Att(i)%fatt(len))
                 error=NF_GET_ATT_INT(ncid,NF_GLOBAL,name,ivals)
                 call netcdf_err( error, mpp_file(unit), attr=mpp_file(unit)%att(i) )
                 if( verbose .and. pe == 0 )print *, 'GLOBAL ATT ',trim(name),' ',ivals(1:len)
                 mpp_file(unit)%Att(i)%fatt(1:len)=ivals(1:len)
              case (NF_FLOAT)
                 allocate(mpp_file(unit)%Att(i)%fatt(len))
                 error=NF_GET_ATT_REAL(ncid,NF_GLOBAL,name,rvals)
                 call netcdf_err( error, mpp_file(unit), attr=mpp_file(unit)%att(i) )
                 mpp_file(unit)%Att(i)%fatt(1:len)=rvals(1:len)
                 if( verbose .and. pe == 0)print *, 'GLOBAL ATT ',trim(name),' ',mpp_file(unit)%Att(i)%fatt(1:len)
              case (NF_DOUBLE)
                 allocate(mpp_file(unit)%Att(i)%fatt(len))
                 error=NF_GET_ATT_DOUBLE(ncid,NF_GLOBAL,name,r8vals)
                 call netcdf_err( error, mpp_file(unit), attr=mpp_file(unit)%att(i) )
                 mpp_file(unit)%Att(i)%fatt(1:len)=r8vals(1:len)
                 if( verbose .and. pe == 0)print *, 'GLOBAL ATT ',trim(name),' ',mpp_file(unit)%Att(i)%fatt(1:len)
           end select
                 
        enddo
!       
! assign dimension name and length
!
        do i=1,ndim
           error = NF_INQ_DIM(ncid,i,name,len);call netcdf_err( error, mpp_file(unit) )
           Axis(i)%name = name
           Axis(i)%len = len
        enddo
           
        nvar=0
        do i=1, nvar_total
           error=NF_INQ_VAR(ncid,i,name,type,nvdims,dimids,nvatts);call netcdf_err( error, mpp_file(unit) )
           isdim=.false.
           do j=1,ndim
              if( trim(lowercase(name)).EQ.trim(lowercase(Axis(j)%name)) )isdim=.true.
           enddo
           if (.not.isdim) nvar=nvar+1
        enddo
        mpp_file(unit)%nvar = nvar
        allocate(mpp_file(unit)%Var(nvar))
        
        do i=1,nvar
           mpp_file(unit)%Var(i) = default_field
        enddo
           
!       
! assign dimension info
!
        do i=1, nvar_total
           error=NF_INQ_VAR(ncid,i,name,type,nvdims,dimids,nvatts);call netcdf_err( error, mpp_file(unit) )
           isdim=.false.
           do j=1,ndim
              if( trim(lowercase(name)).EQ.trim(lowercase(Axis(j)%name)) )isdim=.true.
           enddo
              
           if( isdim )then
              error=NF_INQ_DIMID(ncid,name,dimid);call netcdf_err( error, mpp_file(unit), string=' Axis='//name )
              Axis(dimid)%type = type
              Axis(dimid)%did = dimid
              Axis(dimid)%id = i
              Axis(dimid)%natt = nvatts
              ! get axis values
              if( i.NE.mpp_file(unit)%id )then   ! non-record dims
                 select case (type)
                 case (NF_INT)
                    len=Axis(dimid)%len
                    allocate(Axis(dimid)%data(len))
                    error = NF_GET_VAR_INT(ncid,i,ivals);call netcdf_err( error, mpp_file(unit), axis(dimid) )
                    Axis(dimid)%data(1:len)=ivals(1:len)
                 case (NF_FLOAT)
                    len=Axis(dimid)%len
                    allocate(Axis(dimid)%data(len))
                    error = NF_GET_VAR_REAL(ncid,i,rvals);call netcdf_err( error, mpp_file(unit), axis(dimid) )
                    Axis(dimid)%data(1:len)=rvals(1:len)
                 case (NF_DOUBLE)
                    len=Axis(dimid)%len
                    allocate(Axis(dimid)%data(len))
                    error = NF_GET_VAR_DOUBLE(ncid,i,r8vals);call netcdf_err( error, mpp_file(unit), axis(dimid) )
                    Axis(dimid)%data(1:len) = r8vals(1:len)
                 case default
                    call mpp_error( FATAL, 'Invalid data type for dimension' )
                 end select
             else   
                 len = mpp_file(unit)%time_level
                 allocate(mpp_file(unit)%time_values(len))
                 select case (type)
                 case (NF_FLOAT)
                    error = NF_GET_VAR_REAL(ncid,i,rvals);call netcdf_err( error, mpp_file(unit), axis(dimid) )
                    mpp_file(unit)%time_values(1:len) = rvals(1:len)
                 case (NF_DOUBLE)
                    error = NF_GET_VAR_DOUBLE(ncid,i,r8vals);call netcdf_err( error, mpp_file(unit), axis(dimid) )
                    mpp_file(unit)%time_values(1:len) = r8vals(1:len)
                 case default
                    call mpp_error( FATAL, 'Invalid data type for dimension' )
                 end select
              endif 
              ! assign dimension atts
              if( nvatts.GT.0 )allocate(Axis(dimid)%Att(nvatts))
              
              do j=1,nvatts
                 Axis(dimid)%Att(j) = default_att
              enddo
                 
              do j=1,nvatts
                 error=NF_INQ_ATTNAME(ncid,i,j,attname);call netcdf_err( error, mpp_file(unit) )
                 error=NF_INQ_ATT(ncid,i,trim(attname),type,len)
                 call netcdf_err( error, mpp_file(unit), string=' Attribute='//attname )
                 
                 Axis(dimid)%Att(j)%name = trim(attname)
                 Axis(dimid)%Att(j)%type = type
                 Axis(dimid)%Att(j)%len = len
                 
                 select case (type)
                 case (NF_CHAR)
                    if (len.gt.512) call mpp_error(FATAL,'DIM ATT too long')
                    error=NF_GET_ATT_TEXT(ncid,i,trim(attname),Axis(dimid)%Att(j)%catt);
                    call netcdf_err( error, mpp_file(unit), attr=axis(dimid)%att(j) )
                    if( verbose .and. pe == 0 ) &
                         print *, 'AXIS ',trim(Axis(dimid)%name),' ATT ',trim(attname),' ',Axis(dimid)%Att(j)%catt(1:len)
                    ! store integers in float arrays
                    ! assume dimension data not packed
                 case (NF_SHORT)
                    allocate(Axis(dimid)%Att(j)%fatt(len))
                    error=NF_GET_ATT_INT2(ncid,i,trim(attname),i2vals);
                    call netcdf_err( error, mpp_file(unit), attr=axis(dimid)%att(j) )
                    Axis(dimid)%Att(j)%fatt(1:len)=i2vals(1:len)
                    if( verbose .and. pe == 0  ) &
                         print *, 'AXIS ',trim(Axis(dimid)%name),' ATT ',trim(attname),' ',Axis(dimid)%Att(j)%fatt
                 case (NF_INT)
                    allocate(Axis(dimid)%Att(j)%fatt(len))
                    error=NF_GET_ATT_INT(ncid,i,trim(attname),ivals);
                    call netcdf_err( error, mpp_file(unit), attr=axis(dimid)%att(j) )
                    Axis(dimid)%Att(j)%fatt(1:len)=ivals(1:len)
                    if( verbose .and. pe == 0  ) &
                         print *, 'AXIS ',trim(Axis(dimid)%name),' ATT ',trim(attname),' ',Axis(dimid)%Att(j)%fatt
                 case (NF_FLOAT)
                    allocate(Axis(dimid)%Att(j)%fatt(len))
                    error=NF_GET_ATT_REAL(ncid,i,trim(attname),rvals);
                    call netcdf_err( error, mpp_file(unit), attr=axis(dimid)%att(j) )
                    Axis(dimid)%Att(j)%fatt(1:len)=rvals(1:len)
                    if( verbose  .and. pe == 0 ) &
                         print *, 'AXIS ',trim(Axis(dimid)%name),' ATT ',trim(attname),' ',Axis(dimid)%Att(j)%fatt
                 case (NF_DOUBLE)
                    allocate(Axis(dimid)%Att(j)%fatt(len))
                    error=NF_GET_ATT_DOUBLE(ncid,i,trim(attname),r8vals);
                    call netcdf_err( error, mpp_file(unit), attr=axis(dimid)%att(j) )
                    Axis(dimid)%Att(j)%fatt(1:len)=r8vals(1:len)
                    if( verbose  .and. pe == 0 ) &
                         print *, 'AXIS ',trim(Axis(dimid)%name),' ATT ',trim(attname),' ',Axis(dimid)%Att(j)%fatt
                 case default
                    call mpp_error( FATAL, 'Invalid data type for dimension at' )
                 end select
                 ! assign pre-defined axis attributes
                 select case(trim(attname))
                 case('long_name')
                    Axis(dimid)%longname=Axis(dimid)%Att(j)%catt(1:len)
                 case('units')
                    Axis(dimid)%units=Axis(dimid)%Att(j)%catt(1:len)
                 case('cartesian_axis')
                    Axis(dimid)%cartesian=Axis(dimid)%Att(j)%catt(1:len)
                 case('calendar')
                    Axis(dimid)%calendar=Axis(dimid)%Att(j)%catt(1:len)
                    Axis(dimid)%calendar = lowercase(cut0(Axis(dimid)%calendar))
                    if (trim(Axis(dimid)%calendar) == 'none') &
                         Axis(dimid)%calendar = 'no_calendar'
                    if (trim(Axis(dimid)%calendar) == 'no_leap') &
                         Axis(dimid)%calendar = 'noleap'
                    if (trim(Axis(dimid)%calendar) == '365_days') &
                         Axis(dimid)%calendar = '365_day'
                    if (trim(Axis(dimid)%calendar) == '360_days') &
                         Axis(dimid)%calendar = '360_day'
                 case('calendar_type')
                    Axis(dimid)%calendar=Axis(dimid)%Att(j)%catt(1:len)
                    Axis(dimid)%calendar = lowercase(cut0(Axis(dimid)%calendar))
                    if (trim(Axis(dimid)%calendar) == 'none') &
                         Axis(dimid)%calendar = 'no_calendar'
                    if (trim(Axis(dimid)%calendar) == 'no_leap') &
                         Axis(dimid)%calendar = 'noleap'
                    if (trim(Axis(dimid)%calendar) == '365_days') &
                         Axis(dimid)%calendar = '365_day'
                    if (trim(Axis(dimid)%calendar) == '360_days') &
                         Axis(dimid)%calendar = '360_day'
                 case('positive')
                    attval = Axis(dimid)%Att(j)%catt(1:len)
                    if( attval.eq.'down' )then
                       Axis(dimid)%sense=-1
                    else if( attval.eq.'up' )then
                       Axis(dimid)%sense=1
                    endif
                 end select
                    
              enddo
              ! store axis info in filetype
              mpp_file(unit)%Axis(dimid) = Axis(dimid)
           endif
        enddo 
! assign variable info
        nv = 0
        do i=1, nvar_total
           error=NF_INQ_VAR(ncid,i,name,type,nvdims,dimids,nvatts);call netcdf_err( error, mpp_file(unit) )
!          
! is this a dimension variable?
!
           isdim=.false.
           do j=1,ndim
              if( trim(lowercase(name)).EQ.trim(lowercase(Axis(j)%name)) )isdim=.true.
           enddo
              
           if( .not.isdim )then
! for non-dimension variables
              nv=nv+1; if( nv.GT.mpp_file(unit)%nvar )call mpp_error( FATAL, 'variable index exceeds number of defined variables' )
              mpp_file(unit)%Var(nv)%type = type
              mpp_file(unit)%Var(nv)%id = i
              mpp_file(unit)%Var(nv)%name = name
              mpp_file(unit)%Var(nv)%natt = nvatts
! determine packing attribute based on NetCDF variable type
             select case (type)
             case(NF_SHORT)
                 mpp_file(unit)%Var(nv)%pack = 4
             case(NF_FLOAT)
                 mpp_file(unit)%Var(nv)%pack = 2
             case(NF_DOUBLE)
                 mpp_file(unit)%Var(nv)%pack = 1
             case (NF_INT)
                 mpp_file(unit)%Var(nv)%pack = 2
             case default
                   call mpp_error( FATAL, 'Invalid variable type in NetCDF file' )
             end select
! assign dimension ids
              mpp_file(unit)%Var(nv)%ndim = nvdims
              allocate(mpp_file(unit)%Var(nv)%axes(nvdims))
              do j=1,nvdims
                 mpp_file(unit)%Var(nv)%axes(j) = Axis(dimids(j))
              enddo
              allocate(mpp_file(unit)%Var(nv)%size(nvdims))
              
              do j=1,nvdims
                 if( dimids(j).eq.mpp_file(unit)%recdimid )then
                    mpp_file(unit)%Var(nv)%time_axis_index = dimids(j)
                    mpp_file(unit)%Var(nv)%size(j)=1    ! dimid length set to 1 here for consistency w/ mpp_write
                 else
                    mpp_file(unit)%Var(nv)%size(j)=Axis(dimids(j))%len
                 endif
              enddo 
! assign variable atts
              if( nvatts.GT.0 )allocate(mpp_file(unit)%Var(nv)%Att(nvatts))
              
              do j=1,nvatts
                 mpp_file(unit)%Var(nv)%Att(j) = default_att
              enddo
                 
              do j=1,nvatts
                 error=NF_INQ_ATTNAME(ncid,i,j,attname);call netcdf_err( error, mpp_file(unit), field=mpp_file(unit)%Var(nv) )
                 error=NF_INQ_ATT(ncid,i,attname,type,len)
                 call netcdf_err( error, mpp_file(unit),field= mpp_file(unit)%Var(nv), string=' Attribute='//attname )
                 mpp_file(unit)%Var(nv)%Att(j)%name = trim(attname)
                 mpp_file(unit)%Var(nv)%Att(j)%type = type
                 mpp_file(unit)%Var(nv)%Att(j)%len = len
                 
                 select case (type)
                   case (NF_CHAR)
                     if (len.gt.512) call mpp_error(FATAL,'VAR ATT too long')
                     error=NF_GET_ATT_TEXT(ncid,i,trim(attname),mpp_file(unit)%Var(nv)%Att(j)%catt(1:len))
                     call netcdf_err( error, mpp_file(unit), field=mpp_file(unit)%var(nv), attr=mpp_file(unit)%var(nv)%att(j) )
                     if (verbose .and. pe == 0 )&
                           print *, 'Var ',nv,' ATT ',trim(attname),' ',mpp_file(unit)%Var(nv)%Att(j)%catt(1:len)
! store integers as float internally
                   case (NF_SHORT)
                     allocate(mpp_file(unit)%Var(nv)%Att(j)%fatt(len))
                     error=NF_GET_ATT_INT2(ncid,i,trim(attname),i2vals)
                     call netcdf_err( error, mpp_file(unit), field=mpp_file(unit)%var(nv), attr=mpp_file(unit)%var(nv)%att(j) )
                     mpp_file(unit)%Var(nv)%Att(j)%fatt(1:len)= i2vals(1:len)
                     if( verbose  .and. pe == 0 )&
                          print *, 'Var ',nv,' ATT ',trim(attname),' ',mpp_file(unit)%Var(nv)%Att(j)%fatt
                   case (NF_INT)
                     allocate(mpp_file(unit)%Var(nv)%Att(j)%fatt(len))
                     error=NF_GET_ATT_INT(ncid,i,trim(attname),ivals)
                     call netcdf_err( error, mpp_file(unit), field=mpp_file(unit)%var(nv), attr=mpp_file(unit)%var(nv)%att(j) )
                     mpp_file(unit)%Var(nv)%Att(j)%fatt(1:len)=ivals(1:len)
                     if( verbose .and. pe == 0  )&
                          print *, 'Var ',nv,' ATT ',trim(attname),' ',mpp_file(unit)%Var(nv)%Att(j)%fatt
                   case (NF_FLOAT)
                     allocate(mpp_file(unit)%Var(nv)%Att(j)%fatt(len))
                     error=NF_GET_ATT_REAL(ncid,i,trim(attname),rvals)
                     call netcdf_err( error, mpp_file(unit), field=mpp_file(unit)%var(nv), attr=mpp_file(unit)%var(nv)%att(j) )
                     mpp_file(unit)%Var(nv)%Att(j)%fatt(1:len)=rvals(1:len)
                     if( verbose  .and. pe == 0 )&
                          print *, 'Var ',nv,' ATT ',trim(attname),' ',mpp_file(unit)%Var(nv)%Att(j)%fatt
                   case (NF_DOUBLE)
                     allocate(mpp_file(unit)%Var(nv)%Att(j)%fatt(len))
                     error=NF_GET_ATT_DOUBLE(ncid,i,trim(attname),r8vals)
                     call netcdf_err( error, mpp_file(unit), field=mpp_file(unit)%var(nv), attr=mpp_file(unit)%var(nv)%att(j) )
                     mpp_file(unit)%Var(nv)%Att(j)%fatt(1:len)=r8vals(1:len)
                     if( verbose .and. pe == 0  ) &
                          print *, 'Var ',nv,' ATT ',trim(attname),' ',mpp_file(unit)%Var(nv)%Att(j)%fatt
                   case default
                        call mpp_error( FATAL, 'Invalid data type for variable att' )
                 end select
! assign pre-defined field attributes
                 select case (trim(attname))
                    case ('long_name')
                      mpp_file(unit)%Var(nv)%longname=mpp_file(unit)%Var(nv)%Att(j)%catt(1:len)
                    case('units')
                      mpp_file(unit)%Var(nv)%units=mpp_file(unit)%Var(nv)%Att(j)%catt(1:len)
                    case('scale_factor')
                       mpp_file(unit)%Var(nv)%scale=mpp_file(unit)%Var(nv)%Att(j)%fatt(1)
                    case('missing')
                       mpp_file(unit)%Var(nv)%missing=mpp_file(unit)%Var(nv)%Att(j)%fatt(1)
                    case('missing_value')
                       mpp_file(unit)%Var(nv)%missing=mpp_file(unit)%Var(nv)%Att(j)%fatt(1)
                    case('add_offset')
                       mpp_file(unit)%Var(nv)%add=mpp_file(unit)%Var(nv)%Att(j)%fatt(1)
                    case('valid_range')
                       mpp_file(unit)%Var(nv)%min=mpp_file(unit)%Var(nv)%Att(j)%fatt(1)
                       mpp_file(unit)%Var(nv)%max=mpp_file(unit)%Var(nv)%Att(j)%fatt(2)
                 end select
              enddo    
           endif 
        enddo   ! end variable loop
      else 
        call mpp_error( FATAL,  'MPP READ CURRENTLY DOES NOT SUPPORT NON-NETCDF' )
      endif
        
      mpp_file(unit)%initialized = .TRUE.
#else 
      call mpp_error( FATAL, 'MPP_READ currently requires use_netCDF option' )
#endif
      return
    end subroutine mpp_read_meta


    function cut0(string)
      character(len=256) :: cut0
      character(len=*), intent(in) :: string
      integer :: i

      cut0 = string
      i = index(string,achar(0))
      if(i > 0) cut0(i:i) = ' '

      return
    end function cut0


    subroutine mpp_get_tavg_info(unit, field, fields, tstamp, tstart, tend, tavg)
      implicit none
      integer, intent(in) :: unit
      type(fieldtype), intent(in) :: field
      type(fieldtype), intent(in), dimension(:) :: fields
      real(DOUBLE_KIND) , intent(inout), dimension(:) :: tstamp, tstart, tend, tavg
!balaji: added because mpp_read can only read default reals
!      when running with -r4 this will read a default real and then cast double
      real :: t_default_real


      integer :: n, m
      logical :: tavg_info_exists

      tavg = -1.0


      if (size(tstamp,1) /= size(tstart,1)) call mpp_error(FATAL,&
            'size mismatch in mpp_get_tavg_info')
     
      if ((size(tstart,1) /= size(tend,1)) .OR. (size(tstart,1) /= size(tavg,1))) then
          call mpp_error(FATAL,'size mismatch in mpp_get_tavg_info')
      endif
      
      tstart = tstamp
      tend = tstamp
      
      tavg_info_exists = .false.

#ifdef use_netCDF
      do n= 1, field%natt
         if (field%Att(n)%type .EQ. NF_CHAR) then
             if (field%Att(n)%name(1:13) == 'time_avg_info') then
                 tavg_info_exists = .true.
                 exit
             endif   
         endif    
      enddo
#endif   
      if (tavg_info_exists) then
          do n = 1, size(fields(:))
             if (trim(fields(n)%name) == 'average_T1') then
                 do m = 1, size(tstart(:))
                    call mpp_read(unit, fields(n),t_default_real, m)
                    tstart(m) = t_default_real
                 enddo
             endif  
             if (trim(fields(n)%name) == 'average_T2') then
                 do m = 1, size(tend(:))
                    call mpp_read(unit, fields(n),t_default_real, m)
                    tend(m) = t_default_real
                 enddo
             endif  
             if (trim(fields(n)%name) == 'average_DT') then
                 do m = 1, size(tavg(:))
                    call mpp_read(unit, fields(n),t_default_real, m)
                    tavg(m) = t_default_real
                 enddo
             endif  
          enddo  
             
      end if
      return
    end subroutine mpp_get_tavg_info

!#######################################################################


end module mpp_io_read_mod

