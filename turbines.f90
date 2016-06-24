!!
!!  Copyright (C) 2010-2016  Johns Hopkins University
!!
!!  This file is part of lesgo.
!!
!!  lesgo is free software: you can redistribute it and/or modify
!!  it under the terms of the GNU General Public License as published by
!!  the Free Software Foundation, either version 3 of the License, or
!!  (at your option) any later version.
!!
!!  lesgo is distributed in the hope that it will be useful,
!!  but WITHOUT ANY WARRANTY; without even the implied warranty of
!!  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
!!  GNU General Public License for more details.
!!
!!  You should have received a copy of the GNU General Public License
!!  along with lesgo.  If not, see <http://www.gnu.org/licenses/>.
!!

module turbines
! This module contains all of the subroutines associated with drag-disk turbines:

use param
use turbines_base
use grid_m
use messages
use string_util
use wake_model_estimator_class

implicit none

save
private

public :: turbines_init, turbines_forcing, turbine_vel_init, turbines_finalize

real(rprec) :: T_avg_dim_file
real(rprec), dimension(:), allocatable :: z_tot

character (100) :: string1
real(rprec) :: eps !epsilon used for disk velocity time-averaging

integer :: i,j,k,i2,j2,k2,l,s
integer :: imax,jmax,kmax,count_i,count_n
integer :: min_i,max_i,min_j,max_j,min_k,max_k
integer :: k_start, k_end
logical :: exst

logical :: turbine_in_proc=.false.      !init, do not change this

integer, dimension(:), allocatable :: turbine_in_proc_array
#ifdef PPMPI
integer :: turbine_in_proc_cnt = 0
logical :: buffer_logical
#endif
integer, dimension(:), allocatable :: file_id
integer :: fid_k, fid_U_infty, fid_Phat, fid_u
! integer :: counter = 0

type(wakeModelEstimator) :: wm_est
! real(rprec) :: next_opt_time

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
contains
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

subroutine turbines_init()
!  This subroutine creates the 'turbine' folder and starts the turbine forcing output files.
!  It also creates the indicator function (Gaussian-filtered from binary locations - in or out)
!  and sets values for turbine type (node locations, etc)
use functions, only : linear_interp
use open_file_fid_mod
implicit none

real(rprec), pointer, dimension(:) :: x,y,z
character (*), parameter :: sub_name = mod_name // '.turbines_init'
integer :: fid
real(rprec) :: delta2

nullify(x,y,z)

x => grid % x
y => grid % y
z => grid % z

! Allocate and initialize
allocate(turbine_in_proc_array(nproc-1))
allocate(z_tot(nz_tot))
allocate(file_id(nloc))
turbine_in_proc_array = 0

!Create turbine directory
call system("mkdir -vp turbine") 

!z_tot for total domain (since z is local to the processor)
do k=1,nz_tot
    z_tot(k) = (k - 0.5_rprec) * dz
enddo

!Compute a lookup table object for the indicator function 
delta2 = alpha**2 * (dx**2 + dy**2 + dz**2)
do s = 1, nloc
    call  wind_farm%turbine(s)%turb_ind_func%init(delta2, wind_farm%turbine(s)%thk,     &
          wind_farm%turbine(s)%dia, max( max(nx, ny), nz) )
end do

!find turbine nodes - including filtered ind, n_hat, num_nodes, and nodes for each turbine
!each processor finds turbines in its domain
call turbines_nodes

if (turbine_cumulative_time) then
    if (coord == 0) then
        string1 = path // 'turbine/turbine_u_d_T.dat'
        inquire (file=string1, exist=exst)
        if (exst) then
            write(*,*) 'Reading from file turbine_u_d_T.dat'
            fid = open_file_fid( string1, 'rewind', 'formatted' )
            do i=1,nloc
                read(fid,*) wind_farm%turbine(i)%u_d_T    
            enddo    
            read(fid,*) T_avg_dim_file
            if (T_avg_dim_file /= T_avg_dim) then
                write(*,*) 'Time-averaging window does not match value in turbine_u_d_T.dat'
            endif
            close (fid)
        else  
            write (*, *) 'File ', trim(string1), ' not found'
            write (*, *) 'Assuming u_d_T = -20. for all turbines'
            do k=1,nloc
                wind_farm%turbine(k)%u_d_T = -20.
            enddo
        endif                                    
    endif
else
    write (*, *) 'Assuming u_d_T = -20 for all turbines'
    do k=1,nloc
        wind_farm%turbine(k)%u_d_T = -20.
    enddo    
endif
   
if (coord .eq. nproc-1) then
    string1=path // 'output/vel_top_of_domain.dat'
    fid = open_file_fid( string1, 'rewind', 'formatted' )
    write(fid,*) 'total_time','u_HI'
    close(fid)
endif

! Generate the files for the turbine forcing output
do s=1,nloc
   if(coord==0) then
   call string_splice( string1, path // 'turbine/turbine_', s, '.dat' )
   file_id(s) = open_file_fid( string1, 'append', 'formatted' )
   endif
enddo

nullify(x,y,z)

! if (turbine_control == 2) then
!     use_wake_model = .true.
! end if

if (use_wake_model) then
    call wake_model_est_init
end if

! if (turbine_control == 2) then
! #ifdef PPMPI
!     if (coord == 0) then
!         call rh_control_init
!     end if
!     call transfer_Ctp_list
! #else 
!     call rh_control_init
! #endif
! end if

end subroutine turbines_init
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
subroutine wake_model_est_init
use param, only : u_star, CHAR_BUFF_LENGTH
use open_file_fid_mod
use wake_model_class
use functions, only : linear_interp
implicit none

real(rprec) :: U_infty, wm_Delta, wm_Dia
real(rprec), dimension(:), allocatable :: wm_Ctp, wm_k, wm_s
real(rprec) :: ind_factor
integer :: i
logical :: exst

string1 = path // 'wake_model/wm_est.dat'
inquire (file=string1, exist=exst)

if (exst) then
    write(*,*) 'Reading wake model estimator data from wake_model/'
    wm_est = WakeModelEstimator(path // 'wake_model')
else
    wm_Dia = dia_all*z_i
    wm_Delta = 0.5 * wm_Dia

    allocate( wm_Ctp(num_x) )
    allocate( wm_k(num_x) )
    allocate( wm_s(num_x) )

    wm_k = 0.05_rprec

    do i = 1, num_x
        wm_s(i)   = wind_farm%turbine((i-1)*num_y + 1)%xloc * z_i
        wm_Ctp(i) = Ct_prime
    end do 

    U_infty = 0
    do i = 1, num_y
        ind_factor =  wind_farm%turbine(i)%Ct_prime / ( 4.d0 + wind_farm%turbine(i)%Ct_prime )
        U_infty = U_infty - (wind_farm%turbine(i)%u_d_T * u_star / (1._rprec - ind_factor))**3 / num_y 
    end do
    U_infty = U_infty**(1._rprec/3._rprec)

    wm_est = WakeModelEstimator(wm_s, U_infty, wm_Delta, wm_k, wm_Dia, Nx, num_ensemble, &
                                sigma_du, sigma_k, sigma_Phat, tau_U_infty)
    call wm_est%generateInitialEnsemble(wm_Ctp)
end if

! Generate the files for the wake model estimator
string1 = trim( path // 'turbine/wake_model_U_infty.dat' )
fid_U_infty = open_file_fid( string1, 'append', 'formatted' )
string1 = trim( path // 'turbine/wake_model_k.dat' )
fid_k = open_file_fid( string1, 'append', 'formatted' )
string1 = trim( path // 'turbine/wake_model_Phat.dat' )
fid_Phat = open_file_fid( string1, 'append', 'formatted' )
string1 = trim( path // 'turbine/wake_model_u.dat' )
fid_u = open_file_fid( string1, 'append', 'formatted' )

end subroutine wake_model_est_init
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! subroutine rh_control_init
! use rh_control
! use conjugate_gradient_class
! use open_file_fid_mod
! implicit none
! 
! type(MinimizedFarm) :: mfarm
! type(ConjugateGradient) :: cg
! integer :: num_list
! integer :: fid
! 
! next_opt_time = total_time_dim + advancement_time
! 
! string1 = path // 'turbine/turbine_Ctp_list.dat'
! inquire (file=string1, exist=exst)
! if (exst) then
!     write(*,*) 'Reading from file turbine_Ctp_list.dat'
!     fid = open_file_fid( string1, 'rewind', 'formatted' )
!     read(fid,*) num_list
!     allocate( t_Ctp_list(num_list) )
!     allocate( Ctp_list(nloc, num_list) )
!     read(fid,*) t_Ctp_list
!     do i=1,nloc
!         read(fid,*) Ctp_list(i,:)  
!     enddo
!     close (fid)
! else  
!     allocate( t_Ctp_list(2) )
!     allocate( Ctp_list(nloc, 2) )
!     t_Ctp_list(1) = total_time_dim
!     t_Ctp_list(2) = next_opt_time-0.000009_rprec
!     Ctp_list = Ct_prime
! endif
! 
! end subroutine rh_control_init
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! subroutine rh_set_Ctp_list(t_in, Ctp_in)
! implicit none
! real(rprec), dimension(:), intent(in) :: t_in
! real(rprec), dimension(:,:), intent(in) :: Ctp_in
! integer :: i, j, num_t_include, Nt, t_include_start, t_include_stop
! real(rprec), dimension(:), allocatable :: t_temp
! real(rprec), dimension(:,:), allocatable :: Ctp_temp
! 
! ! Count the number of entries to keep
! num_t_include = 0
! t_include_start = -1
! do i = 1, size(t_Ctp_list)
!     if ( t_include_start < 0 ) then
!         if ( t_Ctp_list(i) >= total_time_dim - advancement_time) then
!             t_include_start = i
!             num_t_include = 1
!         end if
!     else
!         if ( t_Ctp_list(i) < next_opt_time ) then
!             num_t_include = num_t_include + 1
!         else 
!             exit
!         end if
!     end if
! end do
! 
! Nt = num_t_include + size(t_in)
! t_include_stop = t_include_start + num_t_include - 1
! ! write(*,*) 'here:', num_t_include, t_include_start, t_include_stop
! 
! ! Store old values in temporary arrays
! t_temp = t_Ctp_list
! Ctp_temp = Ctp_list
! 
! ! Reallocate the size of the list
! deallocate(Ct_prime_time)
! deallocate(Ct_prime_arr)
! allocate( Ct_prime_time(Nt)  )
! allocate( Ct_prime_arr(nloc, Nt) )
! 
! ! Place old values into array
! Ct_prime_time(1:num_t_include) = t_temp(t_include_start:t_include_stop)
! Ct_prime_arr(:,1:num_t_include) = Ctp_temp(:,t_include_start:t_include_stop)
! 
! ! Place new values into array
! t_Ctp_list(num_t_include+1:) = t_in
! do i = 1, num_x
!     do j = 1, num_y
!         Ctp_list((i-1)*num_y+j,num_t_include+1:) = Ctp_in(i,:)
!     end do
! end do
! ! 
! ! write(*,*) 't_Ctp_list:'
! ! write(*,*) t_Ctp_list
! ! write(*,*) 'Ctp_list:'
! ! write(*,*) Ctp_list
! 
! deallocate(t_temp)
! deallocate(Ctp_temp)
! 
! end subroutine rh_set_Ctp_list
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

#ifdef PPMPI
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! subroutine transfer_Ctp_list
! implicit none
! integer :: i, j, Nt, Ntemp
! real(rprec), dimension(:), allocatable :: temp_array
! 
! ! Transfer the size of t_Ctp_list
! call mpi_barrier (comm, ierr)
! if (coord == 0) then 
!     Nt = size(t_Ctp_list)
!     do i = 1, turbine_in_proc_cnt
!         call MPI_send( Nt, 1, MPI_rprec, i, 3, comm, ierr )
!     end do
! elseif (turbine_in_proc) then
!     call MPI_recv( Nt, 1, MPI_rprec, 0, 3, comm, status, ierr )
! end if
! 
! ! Allocate the lists if needed
! if ( coord /= 0 .and. allocated(t_Ctp_list) ) then
!     deallocate(t_Ctp_list)
!     deallocate(Ctp_list)
! end if
! 
! Ntemp = Nt * (num_x + 1)
! allocate( temp_array(Ntemp) )
! call mpi_barrier (comm, ierr)
! if (coord == 0) then 
!     temp_array(1:Nt) = t_Ctp_list
!     do i = 1, num_x
!         temp_array(Nt*i+1:Nt*(i+1)) = Ctp_list(i+num_y*(i-1),:)
!     end do
!     do i = 1, turbine_in_proc_cnt
!         call MPI_send( temp_array, Ntemp, MPI_rprec, i, 3, comm, ierr )
!     end do
! elseif (turbine_in_proc) then
!     allocate( t_Ctp_list(Nt) )
!     allocate( Ctp_list(nloc, Nt) )
!     call MPI_recv( temp_array, Ntemp, MPI_rprec, 0, 3, comm, status, ierr )
!     ! Place new values into array
!     t_Ctp_list = temp_array(1:Nt)
!     do i = 1, num_x
!         do j = 1, num_y
!             Ctp_list((i-1)*num_y+j,:) = temp_array(Nt*i+1:Nt*(i+1))
!         end do
!     end do
!     
! end if
! 
! deallocate(temp_array)
! 
! end subroutine transfer_Ctp_list
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
#endif

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!subroutine turbines_nodes(array) ! removed large 3D array to limit memory use
subroutine turbines_nodes
!This subroutine locates nodes for each turbine and builds the arrays: ind, n_hat, num_nodes, and nodes
implicit none

character (*), parameter :: sub_name = mod_name // '.turbines_nodes'

real(rprec) :: rx,ry,rz,r,r_norm,r_disk

real(rprec), pointer :: p_xloc => null(), p_yloc => null(), p_height => null()
real(rprec), pointer :: p_dia => null(), p_thk => null(), p_theta1 => null(), p_theta2 => null()
real(rprec), pointer :: p_nhat1 => null(), p_nhat2=> null(), p_nhat3 => null() 
integer :: icp, jcp, kcp

#ifdef PPMPI
real(rprec), dimension(:), allocatable :: buffer_array
#endif
real(rprec), pointer, dimension(:) :: x, y, z

real(rprec) :: filt
real(rprec), dimension(:), allocatable :: sumA, turbine_vol

nullify(x,y,z)

x => grid % x
y => grid % y
z => grid % z

turbine_in_proc = .false.

allocate(sumA(nloc))
allocate(turbine_vol(nloc))
sumA = 0

do s=1,nloc
    
    count_n = 0    !used for counting nodes for each turbine
    count_i = 1    !index count - used for writing to array "nodes"

    !set pointers
    p_xloc => wind_farm%turbine(s)%xloc     
    p_yloc => wind_farm%turbine(s)%yloc  
    p_height => wind_farm%turbine(s)%height 
    p_dia => wind_farm%turbine(s)%dia 
    p_thk => wind_farm%turbine(s)%thk
    p_theta1 => wind_farm%turbine(s)%theta1
    p_theta2 => wind_farm%turbine(s)%theta2
    p_nhat1 => wind_farm%turbine(s)%nhat(1)
    p_nhat2 => wind_farm%turbine(s)%nhat(2)
    p_nhat3 => wind_farm%turbine(s)%nhat(3)

    !identify "search area"
    imax = int(p_dia/dx + 2)
    jmax = int(p_dia/dy + 2)
    kmax = int(p_dia/dz + 2)

    !determine unit normal vector for each turbine	
    p_nhat1 = -cos(pi*p_theta1/180.)*cos(pi*p_theta2/180.)
    p_nhat2 = -sin(pi*p_theta1/180.)*cos(pi*p_theta2/180.)
    p_nhat3 = sin(pi*p_theta2/180.)

    !determine nearest (i,j,k) to turbine center
    icp = nint(p_xloc/dx)
    jcp = nint(p_yloc/dy)
    kcp = nint(p_height/dz + 0.5)

    !determine limits for checking i,j,k
    !due to spectral BCs, i and j may be < 1 or > nx,ny
    !the mod function accounts for this when these values are used
    min_i = icp-imax
    max_i = icp+imax
    min_j = jcp-jmax
    max_j = jcp+jmax
    min_k = max((kcp-kmax),1)
    max_k = min((kcp+kmax),nz_tot)
    wind_farm%turbine(s)%nodes_max(1) = min_i
    wind_farm%turbine(s)%nodes_max(2) = max_i
    wind_farm%turbine(s)%nodes_max(3) = min_j
    wind_farm%turbine(s)%nodes_max(4) = max_j
    wind_farm%turbine(s)%nodes_max(5) = min_k
    wind_farm%turbine(s)%nodes_max(6) = max_k      

    !check neighboring grid points	
    !update num_nodes, nodes, and ind for this turbine
    !and split domain between processors
    !z(nz) and z(1) of neighboring coords match so each coord gets (local) 1 to nz-1
    wind_farm%turbine(s)%ind = 0._rprec
    wind_farm%turbine(s)%nodes = 0
    wind_farm%turbine(s)%num_nodes = 0
    count_n = 0
    count_i = 1
#ifdef PPMPI
    k_start = max(1+coord*(nz-1), min_k)
    k_end = min(nz-1+coord*(nz-1), max_k)
#else
    k_start = 1
    k_end = nz
#endif
    
    do k=k_start,k_end  !global k     
        do j=min_j,max_j
            do i=min_i,max_i
                !vector from center point to this node is (rx,ry,rz) with length r
                if (i<1) then
                    i2 = mod(i+nx-1,nx)+1
                    rx = (x(i2)-L_x) - p_xloc
                elseif (i>nx) then
                    i2 = mod(i+nx-1,nx)+1
                    rx = (L_x+x(i2)) - p_xloc
                else
                    i2 = i
                    rx = x(i) - p_xloc 
                endif            
                if (j<1) then
                    j2 = mod(j+ny-1,ny)+1
                    ry = (y(j2)-L_y) - p_yloc                
                elseif (j>ny) then
                    j2 = mod(j+ny-1,ny)+1
                    ry = (L_y+y(j2)) - p_yloc
                else
                    j2 = j
                    ry = y(j) - p_yloc 
                endif                      
                rz = z_tot(k) - p_height 
                r = sqrt(rx*rx + ry*ry + rz*rz)
                !length projected onto unit normal for this turbine
                r_norm = abs(rx*p_nhat1 + ry*p_nhat2 + rz*p_nhat3)
                !(remaining) length projected onto turbine disk
                r_disk = sqrt(r*r - r_norm*r_norm)
                ! get the filter value
                filt = wind_farm%turbine(s)%turb_ind_func%val(r_disk, r_norm)
                if ( filt > filter_cutoff ) then
                    wind_farm%turbine(s)%ind(count_i) = filt
                    wind_farm%turbine(s)%nodes(count_i,1) = i2
                    wind_farm%turbine(s)%nodes(count_i,2) = j2
                    wind_farm%turbine(s)%nodes(count_i,3) = k - coord*(nz-1) !local k
                    count_n = count_n + 1
                    count_i = count_i + 1
                    turbine_in_proc = .true.
                    sumA(s) = sumA(s) + filt * dx * dy * dz
                endif
           enddo
       enddo
    enddo
    wind_farm%turbine(s)%num_nodes = count_n
    
    ! Calculate turbine volume
    turbine_vol(s) = pi/4. * (wind_farm%turbine(s)%dia)**2 * wind_farm%turbine(s)%thk
    
enddo

! Sum the indicator function across all processors if using MPI
#ifdef PPMPI 
allocate(buffer_array(nloc))
buffer_array = sumA
call MPI_Allreduce(buffer_array, sumA, nloc, MPI_rprec, MPI_SUM, comm, ierr)
deallocate(buffer_array)
#endif

! Normalize the indicator function
do s = 1, nloc
    wind_farm%turbine(s)%ind = wind_farm%turbine(s)%ind(:) * turbine_vol(s) / sumA(s)
end do

!each processor sends its value of turbine_in_proc
!if false, disk-avg velocity will not be sent (since it will always be 0.)
#ifdef PPMPI
turbine_in_proc_cnt = 0
if (coord == 0) then
    do i=1,nproc-1
        call MPI_recv(buffer_logical, 1, MPI_logical, i, 2, comm, status, ierr )
        if (buffer_logical) then
            turbine_in_proc_cnt = turbine_in_proc_cnt + 1
            turbine_in_proc_array(turbine_in_proc_cnt) = i
        endif
    enddo
else
    call MPI_send(turbine_in_proc, 1, MPI_logical, 0, 2, comm, ierr )
endif
#endif

! Cleanup
deallocate(sumA)
deallocate(turbine_vol)
nullify(x,y,z)

end subroutine turbines_nodes
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
subroutine turbines_forcing()
! This subroutine applies the drag-disk forcing
use sim_param, only : u,v,w, fxa,fya,fza
use functions, only : linear_interp, interp_to_uv_grid
! use rh_control
implicit none

character (*), parameter :: sub_name = mod_name // '.turbines_forcing'

real(rprec), pointer :: p_u_d => null(), p_u_d_T => null(), p_f_n => null()
real(rprec), pointer :: p_Ct_prime => null()
integer, pointer :: p_icp => null(), p_jcp => null(), p_kcp => null()

real(rprec) :: ind2
real(rprec), dimension(nloc) :: disk_avg_vel, disk_force
real(rprec), dimension(nloc) :: u_vel_center, v_vel_center, w_vel_center
real(rprec), allocatable, dimension(:,:,:) :: w_uv ! Richard: This 3D matrix can relatively easy be prevented
real(rprec), pointer, dimension(:) :: y,z

real(rprec), dimension(:), allocatable :: wm_Pm, wm_Ctp

real(rprec), dimension(4*nloc) :: send_array
#ifdef PPMPI
real(rprec), dimension(4*nloc) :: recv_array
#endif

nullify(y,z)
y => grid % y
z => grid % z

allocate(w_uv(ld,ny,lbz:nz))

#ifdef PPMPI
call mpi_sync_real_array(w, 0, MPI_SYNC_DOWNUP)     !syncing intermediate w-velocities!
#endif

w_uv = interp_to_uv_grid(w, lbz)

! Do interpolation for dynamically changing parameters
do s = 1, nloc
    if (dyn_theta1) wind_farm%turbine(s)%theta1 =                       &
        linear_interp(theta1_time, theta1_arr(s,:), total_time_dim)
    if (dyn_theta2) wind_farm%turbine(s)%theta2 =                       &
        linear_interp(theta2_time, theta2_arr(s,:), total_time_dim)
    if (dyn_Ct_prime) wind_farm%turbine(s)%Ct_prime =                   &
        linear_interp(Ct_prime_time, Ct_prime_arr(s,:), total_time_dim)        
end do

! Recompute the turbine position if theta1 or theta2 can change
if (dyn_theta1 .or. dyn_theta2) call turbines_nodes

!Each processor calculates the weighted disk-averaged velocity
disk_avg_vel = 0._rprec
u_vel_center = 0._rprec
v_vel_center = 0._rprec
w_vel_center = 0._rprec
if (turbine_in_proc) then
    do s=1,nloc       
        ! Calculate total disk-averaged velocity for each turbine (current, instantaneous)    
        ! in the normal direction. The weighted average is calculated using "ind"
        do l=1,wind_farm%turbine(s)%num_nodes   
            i2 = wind_farm%turbine(s)%nodes(l,1)
            j2 = wind_farm%turbine(s)%nodes(l,2)
            k2 = wind_farm%turbine(s)%nodes(l,3)
            disk_avg_vel(s) = disk_avg_vel(s) + (wind_farm%turbine(s)%nhat(1)*u(i2,j2,k2) &
                              + wind_farm%turbine(s)%nhat(2)*v(i2,j2,k2)                  &
                              + wind_farm%turbine(s)%nhat(3)*w_uv(i2,j2,k2))              &
                              * wind_farm%turbine(s)%ind(l)        
        enddo
        
        ! Set pointers
        p_icp => wind_farm%turbine(s)%icp
        p_jcp => wind_farm%turbine(s)%jcp
        p_kcp => wind_farm%turbine(s)%kcp
        
        ! Calculate disk center velocity
        if (wind_farm%turbine(s)%center_in_proc) then
            u_vel_center(s) = u(p_icp, p_jcp, p_kcp)
            v_vel_center(s) = v(p_icp, p_jcp, p_kcp)
            w_vel_center(s) = w_uv(p_icp, p_jcp, p_kcp)
        end if
                
        ! write this value to the array (which will be sent to coord 0)
        send_array(s)        = disk_avg_vel(s)
        send_array(nloc+s)   = u_vel_center(s)
        send_array(2*nloc+s) = v_vel_center(s)
        send_array(3*nloc+s) = w_vel_center(s)
    end do
endif        

!send the disk-avg values to coord==0
#ifdef PPMPI 
call mpi_barrier (comm,ierr)

if (coord == 0) then
    ! Add all received values from other processors
    do i=1,turbine_in_proc_cnt
        j = turbine_in_proc_array(i)
        recv_array = 0._rprec
        call MPI_recv( recv_array, nloc, MPI_rprec, j, 3, comm, status, ierr )
        send_array = send_array + recv_array
    enddo
    
    ! Place summed values into arrays
    do s = 1, nloc
        disk_avg_vel(s) = send_array(s)
        u_vel_center(s) = send_array(nloc+s)
        v_vel_center(s) = send_array(2*nloc+s)
        w_vel_center(s) = send_array(3*nloc+s)
    end do
elseif (turbine_in_proc) then
    call MPI_send( send_array, nloc, MPI_rprec, 0, 3, comm, ierr )
endif
#endif

!Coord==0 takes that info and calculates total disk force, then sends it back
if (coord == 0) then           
    !update epsilon for the new timestep (for cfl_dt)
    if (T_avg_dim > 0.) then
        eps = (dt_dim / T_avg_dim) / (1. + dt_dim / T_avg_dim)
    else
        eps = 1.
    endif
      
    do s=1,nloc
        !set pointers
        p_u_d => wind_farm%turbine(s)%u_d
        p_u_d_T => wind_farm%turbine(s)%u_d_T
        p_f_n => wind_farm%turbine(s)%f_n
        p_Ct_prime => wind_farm%turbine(s)%Ct_prime
        
        !volume correction:
        !since sum of ind is turbine volume/(dx*dy*dz) (not exactly 1.)
        p_u_d = disk_avg_vel(s) * wind_farm%turbine(s)%vol_c

        !add this current value to the "running average" (first order relaxation)
        p_u_d_T = (1.-eps)*p_u_d_T + eps*p_u_d

        !calculate total thrust force for each turbine  (per unit mass)
        !force is normal to the surface (calc from u_d_T, normal to surface)
        !write force to array that will be transferred via MPI    
        p_f_n = -0.5*p_Ct_prime*abs(p_u_d_T)*p_u_d_T/wind_farm%turbine(s)%thk       
        disk_force(s) = p_f_n
        
        !write values to file                   
        if (modulo (jt_total, tbase) == 0) then
            write( file_id(s), *) total_time_dim, u_vel_center(s), v_vel_center(s), &
                    w_vel_center(s), -p_u_d, -p_u_d_T, wind_farm%turbine(s)%theta1, &
                    wind_farm%turbine(s)%theta2, p_Ct_prime
        endif 

    enddo                   
endif

!send total disk force to the necessary procs (with turbine_in_proc==.true.)
#ifdef PPMPI
if (coord == 0) then  
    do i=1,turbine_in_proc_cnt
        j = turbine_in_proc_array(i)
        call MPI_send( disk_force, nloc, MPI_rprec, j, 5, comm, ierr )
    enddo              
elseif (turbine_in_proc) then
    call MPI_recv( disk_force, nloc, MPI_rprec, 0, 5, comm, status, ierr )
endif          
#endif 

! Advance the wake model estimator
! if (use_receding_horizon) then
!     call eval_rh_control
! end if

#ifdef PPMPI
if (use_wake_model .and. coord == 0) then
#else
if (use_wake_model) then
#endif
    ! Input thrust coefficient
    allocate ( wm_Ctp(num_x) )
    do i = 1, num_x
        wm_Ctp(i) = wind_farm%turbine((i-1)*num_y+1)%Ct_prime
    end do

    ! Measure average power along row
    allocate ( wm_Pm(num_x) )
    wm_Pm = 0._rprec
    do i = 1, num_x
        do j = 1,num_y
            wm_Pm(i) = wm_Pm(i) - wm_Ctp(i) * (wind_farm%turbine((i-1)*num_y+j)%u_d_T * u_star)**3 / num_y
        end do
    end do

    ! Advance the estimator with the measurements
    call wm_est%advance(dt_dim, wm_Pm, wm_Ctp)

    ! Write to file
    if (modulo (jt_total, tbase) == 0) then
        write(fid_k, *) total_time_dim, wm_est%wm%k
        write(fid_U_infty, *) total_time_dim, wm_est%wm%U_infty
        write(fid_Phat, *) total_time_dim, wm_est%wm%Phat
        write(fid_u, *) total_time_dim, wm_est%wm%u
    end if
    
    deallocate(wm_Pm)
    deallocate(wm_Ctp)
end if

!apply forcing to each node
if (turbine_in_proc) then
    do s=1,nloc        
        do l=1,wind_farm%turbine(s)%num_nodes
            i2 = wind_farm%turbine(s)%nodes(l,1)
            j2 = wind_farm%turbine(s)%nodes(l,2)
            k2 = wind_farm%turbine(s)%nodes(l,3)
            ind2 = wind_farm%turbine(s)%ind(l)
            fxa(i2,j2,k2) = disk_force(s)*wind_farm%turbine(s)%nhat(1)*ind2
            fya(i2,j2,k2) = disk_force(s)*wind_farm%turbine(s)%nhat(2)*ind2
            fza(i2,j2,k2) = disk_force(s)*wind_farm%turbine(s)%nhat(3)*ind2
        enddo
    enddo
endif

!spatially average velocity at the top of the domain and write to file
if (coord .eq. nproc-1) then
    string1=path // 'output/vel_top_of_domain.dat'
    open(unit=1,file=string1,status='unknown',form='formatted',action='write',position='append')
    write(1,*) total_time, sum(u(:,:,nz-1))/(nx*ny)
    close(1)
endif

! Cleanup
deallocate(w_uv)
nullify(y,z)
nullify(p_icp, p_jcp, p_kcp)

end subroutine turbines_forcing
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
subroutine eval_rh_control
use rh_control
use conjugate_gradient_class
use wake_model_class
use functions, only : linear_interp
implicit none

type(MinimizedFarm) :: mfarm
type(ConjugateGradient) :: cg
! real(rprec), dimension(:,:), allocatable :: Ctp_dummy
! type(WakeModel) :: wm_temp
! real(rprec) :: dt_adv
! integer ::  N_adv
! real(rprec), dimension(:), allocatable :: Ctp_adv
! 
! #ifdef PPMPI
! if (coord == 0) then
! #endif
!     if (total_time_dim > next_opt_time) then
! !     counter = counter + 1
!         ! Advance the counter
!         next_opt_time = total_time_dim + advancement_time
!         
! !         write(*,*) 'total_time_dim, next_opt_time', total_time_dim, next_opt_time
!         
!         ! Advance wake model to next optimization time
!         wm_temp = wm_est%wm
!         N_adv = ceiling( (next_opt_time - total_time_dim) / dt_dim)
!         dt_adv = (next_opt_time - total_time_dim) / N_adv
!         allocate( Ctp_adv(num_x) )
!         do i = 1, N_adv
!             do j = 1, num_x
!                 call linear_interp(t_Ctp_list, Ctp_list((j-1)*num_y+1,:), dt_adv*i + total_time_dim, Ctp_adv(j))
!             end do
! !             write(*,*) 'time, Ctp_adv:'
! !             write(*,*) dt_adv*i + total_time_dim, Ctp_adv
!             call wm_temp%advance(Ctp_adv, dt_adv)
! !             write(*,*) Ctp_adv
!         end do
! !         write(*,*) wm_temp%Ctp
!         
!         ! Set initial guess
!         allocate(Ctp_dummy(num_x, size(t_Ctp_list)))
!         do i = 1, num_x
!             Ctp_dummy(i,:) = Ctp_list((i-1)*num_y+1,:)
!         end do
! !         write(*,*) 't_Ctp_list:'
! !         write(*,*) t_Ctp_list
! !         write(*,*) 'Ctp_dummy:'
! !         write(*,*) Ctp_dummy
! !         write(*,*) 'wm_temp%Ctp:'
! !         write(*,*) wm_temp%Ctp
! !         
        ! Run initial guess in object
        mfarm = MinimizedFarm(wm_est%wm, total_time_dim, horizon_time, 0.99_rprec, Ct_prime, &
                              Pref_time, Pref_arr, rh_gamma, rh_eta)
        call mfarm%run(Ct_prime_time, Ct_prime_arr)
    
        ! Perform optimization
        write(*,*) "Performing next optimization..."
        cg = ConjugateGradient(mfarm, max_iter)
        call cg%minimize(mfarm%get_Ctp_vector())
        call mfarm%makeDimensional
        
! !         write(*,*) 'mfarm%t:'
! !         write(*,*) mfarm%t
! !         write(*,*) 'mfarm%Ctp:'
! !         write(*,*) mfarm%Ctp
! !         write(*,*) 'mfarm%Pfarm:'
! !         write(*,*) mfarm%Pfarm
! 
!         ! Place results into list
!         call rh_set_Ctp_list(mfarm%t, mfarm%Ctp)
!         
!         deallocate(Ctp_dummy)
!         deallocate(Ctp_adv)
!     end if
! 
! #ifdef PPMPI
! end if
! 
! call transfer_Ctp_list
! #endif
! 
end subroutine eval_rh_control
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
subroutine turbines_finalize ()
implicit none

character (*), parameter :: sub_name = mod_name // '.turbines_finalize'

!write disk-averaged velocity to file along with T_avg_dim
!useful if simulation has multiple runs   >> may not make a large difference    
call turbines_checkpoint
    
!deallocate
deallocate(wind_farm%turbine) 
    
end subroutine turbines_finalize
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
subroutine turbines_checkpoint ()
use open_file_fid_mod
implicit none

character (*), parameter :: sub_name = mod_name // '.turbines_checkpoint'
integer :: fid

!write disk-averaged velocity to file along with T_avg_dim
!useful if simulation has multiple runs   >> may not make a large difference
if (coord == 0) then  
    string1 = path // 'turbine/turbine_u_d_T.dat'
    fid = open_file_fid( string1, 'rewind', 'formatted' )
    do i=1,nloc
        write(fid,*) wind_farm%turbine(i)%u_d_T
    enddo           
    write(fid,*) T_avg_dim
    close (fid)
endif

! Checkpoint wake model estimator
#ifdef PPMPI
if (use_wake_model .and. coord == 0) then
#else
if (use_wake_model) then
#endif
    call wm_est%write_to_file(path // 'wake_model')
end if

! Checkpoint receding horizon control
! #ifdef PPMPI
! if (turbine_control == 2 .and. coord == 0) then
! #else
! if (turbine_control == 2) then
! #endif
!     string1 = path // 'turbine/turbine_Ctp_list.dat'
!     fid = open_file_fid( string1, 'rewind', 'formatted' )
!     write(fid,*) size(t_Ctp_list)
!     write(fid,*) t_Ctp_list
!     do i=1,nloc
!         write(fid,*) Ctp_list(i,:)
!     enddo
!     close (fid)
! endif

    
end subroutine turbines_checkpoint
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
subroutine turbine_vel_init(zo_high)
!  called from ic.f90 if initu, lbc_mom==1, S_FLAG are all false.
!  this accounts for the turbines when creating the initial velocity profile.

use param, only: zo
implicit none
character (*), parameter :: sub_name = mod_name // '.turbine_vel_init'

real(rprec), intent(inout) :: zo_high
real(rprec) :: cft, nu_w, exp_KE, induction_factor, Ct_noprime

! Convert Ct' to Ct
! a = Ct'/(4+Ct'), Ct = 4a(1-a)
induction_factor = Ct_prime / (4._rprec + Ct_prime)
Ct_noprime = 4*(induction_factor) * (1 - induction_factor)

! friction coefficient, cft
cft = pi*Ct_noprime/(4.*sx*sy)
       
!wake viscosity
nu_w = 28.*sqrt(0.5*cft)

!turbine friction height, Calaf, Phys. Fluids 22, 2010
zo_high = height_all*(1.+0.5*dia_all/height_all)**(nu_w/(1.+nu_w))* &
  exp(-1.*(0.5*cft/(vonk**2) + (log(height_all/zo* &
  (1.-0.5*dia_all/height_all)**(nu_w/(1.+nu_w))) )**(-2) )**(-0.5) )

exp_KE =  0.5*(log(0.45/zo_high)/0.4)**2
  
if(.false.) then
    write(*,*) 'sx,sy,cft: ',sx,sy,cft
    write(*,*) 'nu_w: ',nu_w    
    write(*,*) 'zo_high: ',zo_high
    write(*,*) 'approx expected KE: ', exp_KE
endif
end subroutine turbine_vel_init
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

end module turbines
